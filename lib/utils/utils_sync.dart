import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ntsapp/utils/common.dart';
import 'package:ntsapp/utils/enums.dart';
import 'package:ntsapp/models/model_category.dart';
import 'package:ntsapp/models/model_change.dart';
import 'package:ntsapp/models/model_file.dart';
import 'package:ntsapp/models/model_item.dart';
import 'package:ntsapp/models/model_item_group.dart';
import 'package:ntsapp/models/model_preferences.dart';
import 'package:ntsapp/models/model_setting.dart';
import 'package:ntsapp/services/service_events.dart';
import 'package:ntsapp/services/service_logger.dart';
import 'package:ntsapp/storage/storage_secure.dart';
import 'package:ntsapp/storage/storage_sqlite.dart';
import 'package:ntsapp/utils/utils_crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as path;

import '../models/model_item_file.dart';

class SyncUtils {
  // Singleton setup
  static final SyncUtils _instance = SyncUtils._internal();
  factory SyncUtils() => _instance;
  SyncUtils._internal();

  Timer? _debounceTimer;
  Timer? _syncTimer;
  Timer? _processTimer;
  bool _hasPendingChanges = false;
  // A sync request that arrived while another sync was running.
  bool _syncAgain = false;
  // True only while a sync cycle is actually running.
  //
  // This used to be derived from the persisted `processRunningAt` timestamp,
  // but that value is written at the start of a cycle and refreshed by a
  // 1s timer while it runs - it is never cleared when the cycle ends. The
  // stale timestamp therefore made the *next* legitimate run look like an
  // overlapping one, so the request was parked in `_syncAgain` with no sync
  // running to pick it up. Both the push (new notes) and the pull (notes
  // arriving from another device) were silently dropped that way.
  bool _isSyncing = false;
  static final logger = AppLogger(prefixes: [
    "utils_sync",
  ]);
  static final String processRunningAt = "sync_running_at";

  void startAutoSync() {
    // Starts the interval sync
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(Duration(minutes: 1), (timer) {
      waitAndSyncChanges();
    });
  }

  void stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  static RealtimeChannel? _syncChannel;
  static bool _realtimeStarting = false;
  static Timer? _realtimeRetryTimer;
  static int _realtimeRetryDelay = 5;

  // Listen for pushes from the user's other devices via Supabase Realtime.
  //
  // This is the fast path for cross-device sync; the 60s auto-sync timer
  // (startAutoSync) is only the fallback. The subscription does NOT survive an
  // app restart, so this must be called again on every startup/resume. It is
  // idempotent unless `restart` is true.
  static Future<void> startRealtimeSync({bool restart = false}) async {
    if (simulateOnboarding()) return;
    if (_syncChannel != null && !restart) return;
    if (_realtimeStarting) return;
    String? userId = getSignedInUserId();
    if (userId == null) return;
    _realtimeStarting = true;
    try {
      String deviceId = await ModelPreferences.get(AppString.deviceId.string,
          defaultValue: "");
      await stopRealtimeSync();
      final channel = Supabase.instance.client.channel('sync-events');
      _syncChannel = channel;
      channel
          .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'sync_events',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) {
          final eventDeviceId = payload.newRecord['device_id'];
          logger.info("Realtime event received from device:$eventDeviceId");
          if (eventDeviceId != deviceId) {
            waitAndSyncChanges();
          }
        },
      )
          .subscribe((status, error) {
        logger.info(
            "Realtime channel status:$status${error == null ? "" : "|$error"}");
        if (status == RealtimeSubscribeStatus.subscribed) {
          _realtimeRetryDelay = 5;
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          // Drop the broken channel so the retry can create a fresh one.
          if (identical(_syncChannel, channel)) {
            unawaited(stopRealtimeSync());
          }
          _scheduleRealtimeRetry();
        }
      });
      logger.info("Realtime sync listener started");
    } catch (e, s) {
      logger.error("startRealtimeSync", error: e, stackTrace: s);
      _scheduleRealtimeRetry();
    } finally {
      _realtimeStarting = false;
    }
  }

  static void _scheduleRealtimeRetry() {
    if (_realtimeRetryTimer != null) return;
    final int delay = _realtimeRetryDelay;
    _realtimeRetryDelay = delay < 30 ? delay * 2 : 60;
    _realtimeRetryTimer = Timer(Duration(seconds: delay), () {
      _realtimeRetryTimer = null;
      unawaited(startRealtimeSync(restart: true));
    });
  }

  static Future<void> stopRealtimeSync() async {
    _realtimeRetryTimer?.cancel();
    _realtimeRetryTimer = null;
    if (_syncChannel != null) {
      try {
        await Supabase.instance.client.removeChannel(_syncChannel!);
      } catch (e, s) {
        logger.error("stopRealtimeSync", error: e, stackTrace: s);
      }
      _syncChannel = null;
    }
  }

  // Static method to trigger change detection
  static void waitAndSyncChanges(
      {bool inBackground = false,
      bool manualSync = false,
      bool firstFetch = false}) {
    _instance._handleChange(inBackground,
        manualSync: manualSync, firstFetch: firstFetch);
  }

  void _handleChange(bool inBackground,
      {bool manualSync = false, bool firstFetch = false}) {
    _hasPendingChanges = true;
    _debounceTimer?.cancel(); // Cancel any ongoing debounce
    _debounceTimer = Timer(Duration(seconds: 1), () {
      if (_hasPendingChanges) {
        _hasPendingChanges = false;
        triggerSync(inBackground,
            manualSync: manualSync, firstFetch: firstFetch);
      }
    });
  }

  Future<void> triggerSync(bool inBackground,
      {bool manualSync = false, bool firstFetch = false}) async {
    String mode = inBackground ? "Background" : "Foreground";
    logger.info("sync request from:$mode");
    if (_isSyncing) {
      // A sync is already running: remember the request and let the running
      // cycle pick it up when it ends (see the `_syncAgain` handling below).
      _syncAgain = true;
      logger.warning("$mode|Sync|Already Syncing");
      return;
    }
    // Claim the cycle right away - before the first await - so two requests
    // that arrive back to back cannot both start a cycle.
    _isSyncing = true;
    bool hasPendingUploads = false;
    bool hasMoreMapChangesToPush = false;
    try {
      bool canSync = await SyncUtils.canSync();
      if (canSync) {
        int startedAt = DateTime.now().millisecondsSinceEpoch;
        if (!inBackground) {
          // The realtime listener does not survive app restarts; re-arm it here
          // (idempotent) so cross-device changes arrive without waiting for the
          // 60s polling fallback.
          unawaited(startRealtimeSync());
        }
        await ModelPreferences.set(processRunningAt, startedAt);
        // set timer to update running state every seconds
        _processTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
          await ModelPreferences.set(
              processRunningAt, DateTime.now().millisecondsSinceEpoch);
        });
        logger.info("$mode|Sync|------------------START----------------");
        bool removed = await SyncUtils.checkDeviceStatus();
        if (!removed) {
          hasMoreMapChangesToPush = await pushMapChanges();

          // Pull the changes made by the other devices right away. This used
          // to run after the media uploads, so a note sent from another
          // device only showed up once every pending thumbnail had been
          // uploaded - two round trips per thumbnail.
          await fetchMapChanges();

          await deleteFiles();
          await deleteThumbnails();

          await pushThumbnails(startedAt, inBackground);

          await fetchThumbnails();

          // pushing files is a time consuming task
          hasPendingUploads = await pushFiles(startedAt, inBackground);
          // large files over 20 mb are not fetched
          await fetchFiles(startedAt, inBackground);
        }
      } else {
        logger.info("$mode|Sync|skipped (canSync:$canSync)");
      }
    } catch (e) {
      logger.error("⚠ Sync failed: $e");
    } finally {
      // Release the cycle before anything can ask for another one.
      _isSyncing = false;
      _processTimer?.cancel();
      _processTimer = null;
      // Drop the persisted marker as well: leaving it behind made the next
      // run look like it was overlapping the one that just finished.
      await ModelPreferences.delete(processRunningAt);
    }
    if (manualSync) {
      // Send Signal to update home with DND category
      await signalToUpdateHome();
    }
    if (firstFetch) {
      // Send Signal to update home with DND category
      await signalToUpdateHome();
      EventStream().publish(AppEvent(type: EventType.serverFirstFetchEnds));
    }
    logger.info("$mode|Sync|------------------ENDED----------------");
    if (!inBackground && (hasPendingUploads || hasMoreMapChangesToPush)) {
      logger.info("$mode|Sync| more tasks.. will continue..");
      _handleChange(inBackground, manualSync: manualSync);
    }
    if (_syncAgain) {
      // A change arrived while this sync was running (e.g. a realtime event).
      _syncAgain = false;
      logger.info("$mode|Sync| queued change found, syncing again..");
      _handleChange(inBackground, manualSync: manualSync);
    }
  }

  static String? getSignedInUserId() {
    if (simulateOnboarding()) {
      if (ModelSetting.get(AppString.signedIn.string, "no") == "yes") {
        return "tester";
      } else {
        return null;
      }
    }
    bool supabaseInitialized =
        ModelSetting.get(AppString.supabaseInitialized.string, "no") == "yes";
    if (!supabaseInitialized) return null;
    SupabaseClient supabaseClient = Supabase.instance.client;
    User? currentUser = supabaseClient.auth.currentUser;
    if (currentUser != null) {
      return currentUser.id;
    } else {
      return null;
    }
  }

  static String? getSignedInEmailId() {
    if (simulateOnboarding()) {
      return "tester@notesafe.app";
    }
    bool supabaseInitialized =
        ModelSetting.get(AppString.supabaseInitialized.string, "no") == "yes";
    if (!supabaseInitialized) return null;
    SupabaseClient supabaseClient = Supabase.instance.client;
    User? currentUser = supabaseClient.auth.currentUser;
    if (currentUser != null) {
      return currentUser.email;
    } else {
      return null;
    }
  }

  static Future<String?> getMasterKey() async {
    String? signedInUserId = getSignedInUserId();
    if (signedInUserId == null) {
      return null;
    }
    SecureStorage storage = SecureStorage();
    String keyForMasterKey = '${signedInUserId}_mk';
    String? masterKeyBase64 = await storage.read(key: keyForMasterKey);
    return masterKeyBase64;
  }

  // to sync, one must have masterKey with an active plan
  static Future<bool> canSync() async {
    String? masterKey = await getMasterKey();
    bool hasKeys = masterKey != null;
    return hasKeys;
  }

  static Future<bool> checkDeviceStatus() async {
    bool removed = false;
    if (simulateOnboarding()) {
      return removed;
    }
    try {
      SupabaseClient supabaseClient = Supabase.instance.client;
      String deviceId = await ModelPreferences.get(AppString.deviceId.string,
          defaultValue: "");
      Map<String, dynamic>? row = await supabaseClient
          .from("devices")
          .select("status")
          .eq("id", deviceId)
          .maybeSingle();
      int status = row == null ? 0 : row["status"];
      if (status == 0) {
        // signout
        await signout();
        // wipe out local data
        await ModelCategory.deleteAll();
        removed = true;
        // Send Signal to update home with DND category
        await signalToUpdateHome();
      }
      logger.info("device Status Checked");
    } catch (e, s) {
      logger.error("checkDeviceStatus", error: e, stackTrace: s);
    }
    return removed;
  }

  static Future<bool> signout() async {
    bool success = false;
    String? userId = SyncUtils.getSignedInUserId();
    if (userId != null) {
      String? deviceId = await ModelPreferences.get(AppString.deviceId.string);
      SecureStorage storage = SecureStorage();
      SupabaseClient supabase = Supabase.instance.client;
      try {
        await stopRealtimeSync();
        if (simulateOnboarding()) {
          await ModelCategory.deleteAll();
        } else {
          if (deviceId != null) {
            await supabase.functions.invoke("remove_device",
                headers: {"deviceId": deviceId}, body: {});
          }
          await supabase.auth.signOut();
        }
        String keyForMasterKey = '${userId}_mk';
        String keyForAccessKey = '{$userId}_ak';
        String keyForPasswordKey = '{$userId}_pk';
        String keyForKeyType = '${userId}_kt';
        await storage.delete(key: keyForMasterKey);
        await storage.delete(key: keyForAccessKey);
        await storage.delete(key: keyForKeyType);
        await storage.delete(key: keyForPasswordKey);
        await ModelPreferences.delete(AppString.hasValidPlan.string);
        await ModelPreferences.delete(AppString.deviceId.string);
        await ModelPreferences.delete(AppString.deviceRegistered.string);
        await ModelPreferences.delete(AppString.hasEncryptionKeys.string);
        await ModelPreferences.delete(AppString.debugCipherData.string);
        await ModelPreferences.delete(AppString.encryptionKeyType.string);
        await ModelPreferences.delete(
            AppString.pushedLocalContentForSync.string);
        await ModelPreferences.delete(AppString.lastChangesFetchedAt.string);
        await ModelPreferences.delete(AppString.dataSeeded.string);
        await ModelSetting.set(AppString.signedIn.string, "no");
        await ModelSetting.set(AppString.simulateTesting.string, "no");
        // Send Signal to update home with DND category
        await signalToUpdateHome();
        success = true;
      } on FunctionException catch (e) {
        Map<String, dynamic> errorMap =
            e.details is String ? jsonDecode(e.details) : e.details;
        dynamic error = errorMap.containsKey("error") ? errorMap["error"] : "";
        logger.error("signout", error: error);
      } catch (e, s) {
        logger.error("signout", error: e, stackTrace: s);
      }
    }
    return success;
  }

  // called once when sync gets enabled
  static Future<void> pushLocalChanges() async {
    await ModelPreferences.set(AppString.hasEncryptionKeys.string, "yes");
    logger.info("pushing local content");
    // listen for pushes from other devices via Realtime
    await startRealtimeSync();
    //push categories
    List<Map<String, dynamic>> categories =
        await ModelCategory.getAllRawRowsMap();
    List<Map<String, dynamic>> mutableCategories = categories
        .map((category) => Map<String, dynamic>.from(category))
        .toList();
    for (Map<String, dynamic> category in mutableCategories) {
      category.addAll({"table": "category"});
      await encryptAndPushChange(category, pushToSync: false);
    }
    //push groups
    List<Map<String, dynamic>> groups = await ModelGroup.getAllRawRowsMap();
    List<Map<String, dynamic>> mutableGroups =
        groups.map((group) => Map<String, dynamic>.from(group)).toList();
    for (Map<String, dynamic> group in mutableGroups) {
      group.addAll({"table": "itemgroup"});
      await encryptAndPushChange(group, pushToSync: false);
    }
    //push items
    List<Map<String, dynamic>> items = await ModelItem.getAllRawRowsMap();
    List<Map<String, dynamic>> mutableItems =
        items.map((item) => Map<String, dynamic>.from(item)).toList();
    for (Map<String, dynamic> item in mutableItems) {
      item.addAll({"table": "item"});
      await encryptAndPushChange(item, pushToSync: false);
    }
    if (simulateOnboarding()) {
      // a little delay to keep the screen "Encrypting Notes"
      await Future.delayed(const Duration(seconds: 2));
    }
    await ModelPreferences.set(
        AppString.pushedLocalContentForSync.string, "yes");
    EventStream().publish(AppEvent(type: EventType.serverFirstFetchStarts));
    waitAndSyncChanges(firstFetch: true);
  }

  static Future<void> encryptAndPushChange(Map<String, dynamic> map,
      {bool mediaChanges = true,
      int deleteTask = 0,
      bool pushToSync = true}) async {
    String? masterKeyBase64 = await getMasterKey();
    String? userId = getSignedInUserId();
    if (masterKeyBase64 != null && userId != null) {
      String deviceId = await ModelPreferences.get(AppString.deviceId.string);

      // fetch thumbnail and set it as boolean
      String? thumbnail =
          getValueFromMap(map, 'thumbnail', defaultValue: null); //base64encoded
      map['thumbnail'] = thumbnail == null ? 0 : 1;
      String table = map["table"];
      String rowId = map['id'];
      String changeId = '$userId|$rowId';
      int updatedAt = map['updated_at'];
      map["deleted"] = deleteTask;

      Map<String, dynamic> changeMap = {
        "id": changeId,
        "user_id": userId,
        "updated_at": updatedAt,
        "device_id": deviceId
      };

      SodiumSumo sodium = await SodiumSumoInit.init();
      CryptoUtils cryptoUtils = CryptoUtils(sodium);

      String jsonString = jsonEncode(map);
      Uint8List plainBytes = Uint8List.fromList(utf8.encode(jsonString));
      Uint8List masterKeyBytes = base64Decode(masterKeyBase64);

      Map<String, dynamic> encryptedDataMap =
          cryptoUtils.getEncryptedBytesMap(plainBytes, masterKeyBytes);

      changeMap.addAll(encryptedDataMap);

      String changeData = jsonEncode(changeMap);
      Map<String, dynamic>? dataMap;
      if (map.containsKey('data') && map['data'] != null) {
        if (map['data'] is String) {
          dataMap = jsonDecode(map['data']);
        } else if (map['data'] is Map) {
          dataMap = map['data'];
        }
      }
      SyncChangeTask changeTask = SyncChangeTask.pushMap;
      if (deleteTask == 0) {
        SyncChangeTask? pending = await ModelChange.getTaskType(changeId);
        changeTask = ModelChange.nextTaskAfterUpdate(
          table: table,
          thumbnailIsNull: thumbnail == null,
          map: map,
          mediaChanges: mediaChanges,
          pending: pending,
        );
      } else if (deleteTask == 2) {
        changeTask = SyncChangeTask.pushMapDeleteThumbnailFile;
      } else if (deleteTask == 1) {
        changeTask = SyncChangeTask.pushMapDeleteThumbnail;
      }
      if (deleteTask > 0) {
        // delete file pending for upload if exist
        ModelFile? pendingFile = await ModelFile.getForChange(changeId);
        if (pendingFile != null) {
          await pendingFile.delete();
        }
      }
      // add/update change if any upload/download exist
      await ModelChange.addUpdate(changeId, table, changeData, changeTask.value,
          thumbnail: thumbnail, dataMap: dataMap);
      logger.info("encryptAndPushChange:$table|$changeId|${changeTask.value}");
      await ModelChange.updateTypeState(changeId, SyncState.uploading);
      if (pushToSync) waitAndSyncChanges();
    }
  }

  static Future<bool> pushMapChanges() async {
    logger.info("Push Map Changes");
    String deviceId = await ModelPreferences.get(AppString.deviceId.string);
    SupabaseClient supabaseClient = Supabase.instance.client;
    List<Map<String, dynamic>> allChanges = [];
    bool hasMoreChanges = false;
    List<String> changeIds = [];
    for (String table in ["category", "itemgroup", "item"]) {
      List<ModelChange> changes =
          await ModelChange.requiresMapPushForTable(table);
      if (table == "item" && changes.length >= 100) {
        hasMoreChanges = true;
      }
      List<Map<String, dynamic>> changeMaps = [];
      for (ModelChange change in changes) {
        changeMaps.add(jsonDecode(change.data));
        changeIds.add(change.id);
      }
      if (changeMaps.isNotEmpty) {
        allChanges.add({"table": table, "changes": changeMaps});
      }
    }
    if (allChanges.isNotEmpty) {
      try {
        if (!simulateOnboarding()) {
          await supabaseClient.functions.invoke("push_changes",
              headers: {"deviceId": deviceId},
              body: {"allChanges": allChanges});
        }
        await ModelChange.upgradeTypeForIds(changeIds);
        await ModelPreferences.set(AppString.hasValidPlan.string, "yes");
        logger.info("Pushed Map Changes");
      } on FunctionException catch (e, s) {
        dynamic details = e.details;
        String error = "";
        try {
          Map<String, dynamic> errorMap =
              details is String ? jsonDecode(details) : details;
          error = errorMap["error"]?.toString() ?? "";
        } catch (_) {
          error = details?.toString() ?? "";
        }
        if (error == "Plan expired") {
          await ModelPreferences.set(AppString.hasValidPlan.string, "no");
          EventStream().publish(AppEvent(type: EventType.checkPlanStatus));
          logger.error("pushMapChanges|Supabase", error: "Plan Expired");
        } else {
          // Keep the changes queued (still type pushMap) so the next sync
          // retries them, and make the failure visible in the logs.
          logger.error(
            "pushMapChanges|Supabase",
            error: "FunctionException ${e.status}: $error",
            stackTrace: s,
          );
        }
      } catch (e, s) {
        logger.error("pushMapChanges|Supabase", error: e, stackTrace: s);
      }
    }
    return hasMoreChanges;
  }

  static Future<void> deleteFiles() async {
    logger.info("Delete Files");
    List<ModelChange> changes = await ModelChange.requiresFileDelete();
    if (changes.isEmpty) return;
    SupabaseClient supabaseClient = Supabase.instance.client;
    for (ModelChange change in changes) {
      await deleteFile(change, supabaseClient);
    }
  }

  static Future<void> deleteFile(
      ModelChange change, SupabaseClient supabaseClient) async {
    Map<String, dynamic>? map = change.map;
    if (map != null && map.containsKey("name") && map["name"].isNotEmpty) {
      String fileName = map["name"];
      String? userId = getSignedInUserId();
      if (userId != null) {
        try {
          // Remove the encrypted bytes from the media bucket (ignore if absent).
          try {
            await supabaseClient.storage
                .from("media")
                .remove(["$userId/$fileName"]);
          } catch (e) {
            logger.warning("deleteFile|storage remove failed:$fileName|$e");
          }
          await supabaseClient
              .from("files")
              .delete()
              .eq("id", "$userId|$fileName");
          await ModelChange.upgradeSyncTask(change.id);
        } catch (e, s) {
          logger.error("deleteFile", error: e, stackTrace: s);
        }
      } else {
        await ModelChange.upgradeSyncTask(change.id);
      }
    } else {
      await ModelChange.upgradeSyncTask(change.id);
    }
  }

  static Future<void> deleteThumbnails() async {
    logger.info("Delete Thumbnails");
    List<ModelChange> changes = await ModelChange.requiresThumbnailDelete();
    if (changes.isEmpty) return;
    SupabaseClient supabaseClient = Supabase.instance.client;
    for (ModelChange change in changes) {
      String fileName = change.id.replaceAll("|", "/");
      try {
        await supabaseClient.storage.from('thmbs').remove([fileName]);
        await supabaseClient.from("thmbs").delete().eq("id", change.id);
        await ModelChange.upgradeSyncTask(change.id);
      } catch (e, s) {
        logger.error("deleteThumbnails", error: e, stackTrace: s);
      }
    }
  }

  static Future<void> pushThumbnails(int startedAt, bool inBackground) async {
    logger.info("Push Thumbnails");
    List<ModelChange> changes = await ModelChange.requiresThumbnailPush();
    if (changes.isEmpty) return;
    for (ModelChange change in changes) {
      String table = change.name;
      String changeId = change.id;
      await pushThumbnail(table, changeId, null);
    }
  }

  static Future<void> pushThumbnail(
    String table,
    String changeId,
    String? thumbnail,
  ) async {
    List<String> userIdRowId = changeId.split("|");
    String userId = userIdRowId[0];
    String rowId = userIdRowId[1];
    thumbnail ??= await ModelChange.getThumbnail(table, rowId);
    if (thumbnail == null) {
      // There is no thumbnail to upload. Leaving the change on this step
      // blocked the file behind it: the change was never advanced, so the
      // media file was never pushed either.
      logger.info("pushThumbnail|no thumbnail to upload|$changeId");
      await ModelChange.upgradeSyncTask(changeId);
      return;
    }
    Uint8List thumbnailBytes = base64Decode(thumbnail);

    String? masterKeyBase64 = await getMasterKey();
    if (masterKeyBase64 == null) {
      logger.error("pushThumbnail|Master key missing");
      return;
    }
    Uint8List masterKeyBytes = base64Decode(masterKeyBase64);

    SodiumSumo sodium = await SodiumSumoInit.init();
    CryptoUtils cryptoUtils = CryptoUtils(sodium);

    Map<String, dynamic> encryptedThumbnailMap =
        cryptoUtils.getEncryptedBytesMap(thumbnailBytes, masterKeyBytes);
    String cipherText = encryptedThumbnailMap[AppString.cipherText.string];
    Uint8List cipherBytes = base64Decode(cipherText);
    if (simulateOnboarding()) {
      await ModelChange.upgradeSyncTask(changeId);
      return;
    }
    try {
      SupabaseClient supabaseClient = Supabase.instance.client;
      await supabaseClient.storage.from('thmbs').uploadBinary(
            '$userId/$rowId',
            cipherBytes,
            fileOptions: const FileOptions(cacheControl: '900', upsert: true),
            retryAttempts: 0,
          );
      // if successful upload key cipher
      Map<String, dynamic> keyCipherMap = {
        "id": changeId,
        AppString.cipherNonce.string:
            encryptedThumbnailMap[AppString.cipherNonce.string],
        AppString.keyCipher.string:
            encryptedThumbnailMap[AppString.keyCipher.string],
        AppString.keyNonce.string:
            encryptedThumbnailMap[AppString.keyNonce.string]
      };
      await supabaseClient.from('thmbs').upsert(keyCipherMap, onConflict: 'id');
      // upgrade change task
      await ModelChange.upgradeSyncTask(changeId);
    } catch (e, s) {
      logger.error("pushThumbnail|Supabase", error: e, stackTrace: s);
    }
  }

  static Future<void> pushProfileChange(Map<String, dynamic> map) async {
    SupabaseClient supabaseClient = Supabase.instance.client;
    int updatedAt = map["updated_at"];
    Map<String, dynamic> changeMap = {"updated_at": updatedAt};
    if (map.containsKey("username")) {
      changeMap["username"] = map["username"];
    }
    if (map.containsKey("url")) {
      changeMap["url"] = map["url"];
    }
    try {
      await supabaseClient
          .from("profiles")
          .update(changeMap)
          .eq('id', map["id"])
          .gt('updated_at', updatedAt);
    } catch (e, s) {
      logger.error("pushProfileChange|Supabase", error: e, stackTrace: s);
    }
  }

  /// Makes sure the group a fetched note belongs to exists locally.
  ///
  /// The local `item` table has a NOT NULL foreign key on `itemgroup(id)`
  /// (ON DELETE CASCADE), so a note whose group has not been synced yet
  /// cannot be inserted - the FK violation aborted the whole pull and no
  /// note ever arrived from the other device.
  ///
  /// When the group is missing, a placeholder group with the *same id* is
  /// created under the DND category. The real group row replaces it as soon
  /// as it is fetched, because its `updated_at` is newer.
  static Future<void> ensureGroupExists(Map<String, dynamic> itemMap) async {
    String groupId = getValueFromMap(itemMap, "group_id", defaultValue: "");
    if (groupId.isEmpty) return;
    final dbHelper = StorageSqlite.instance;
    List<Map<String, dynamic>> rows =
        await dbHelper.getWithId("itemgroup", groupId);
    if (rows.isNotEmpty) return;
    try {
      ModelCategory dndCategory = await ModelCategory.getDND();
      int now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await dbHelper.insert("itemgroup", {
        'id': groupId,
        'category_id': dndCategory.id ?? "",
        'title': getNoteGroupDateTitle(),
        'pinned': 0,
        'position': 0,
        'archived_at': 0,
        'color': colorToHex(getIndexedColor(0)),
        'at': now,
        // 0 keeps the placeholder "older" than the real group row, so the
        // real one always wins when it arrives.
        'updated_at': 0,
        'thumbnail': null,
        'data': null,
        'state': 0,
      });
      logger.info("ensureGroupExists|placeholder group created|$groupId");
    } catch (e, s) {
      logger.error("ensureGroupExists|$groupId", error: e, stackTrace: s);
    }
  }

  /// Applies one encrypted row fetched from the server to the local database.
  ///
  /// Split out of [fetchMapChanges] so a single failing row (for example a
  /// note whose group does not exist locally yet) can be isolated and
  /// retried instead of aborting the whole batch.
  static Future<void> applyFetchedRow(String table,
      Map<String, dynamic> changeMap, Uint8List masterKeyBytes,
      CryptoUtils cryptoUtils) async {
    Uint8List? decryptedBytes =
        cryptoUtils.getDecryptedBytesFromMap(changeMap, masterKeyBytes);
    if (decryptedBytes == null) return;
    String jsonString = utf8.decode(decryptedBytes);
    Map<String, dynamic> map = jsonDecode(jsonString);
    String changeId = changeMap["id"];
    String rowId = map["id"];
    int deleteTask = int.parse(map.remove("deleted").toString());
    bool hasThumbnail =
        int.parse(map.remove("thumbnail").toString()) == 1 ? true : false;
    if (deleteTask > 0) {
      // thumbnail and file already been deleted from server
      switch (table) {
        case "category":
          await ModelCategory.deletedFromServer(rowId);
        case "itemgroup":
          await ModelGroup.deletedFromServer(rowId);
        case "item":
          await ModelItem.deletedFromServer(rowId);
      }
      return;
    }
    Map<String, dynamic>? dataMap;
    switch (table) {
      case "category":
        ModelCategory category = await ModelCategory.fromMap(map);
        await category.upcertFromServer();
      case "itemgroup":
        ModelGroup group = await ModelGroup.fromMap(map);
        await group.upcertFromServer();
      case "item":
        // The group must exist before the note can be inserted (foreign key).
        await ensureGroupExists(map);
        ModelItem item = await ModelItem.fromMap(map);
        dataMap = item.data;
        item.state = SyncState.downloaded.value;
        await item.upcertFromServer();
        // fix file path in data map
        if (dataMap != null) {
          if (dataMap.containsKey("path")) {
            String fileName = dataMap["name"];
            String mimeDirectory = dataMap["mime"].split("/").first;
            String fileOutPath = await getFilePath(mimeDirectory, fileName);
            dataMap["path"] = fileOutPath;
            item.data = dataMap;
            await item.update(["data"], pushToSync: false);
            // check file
            File fileOut = File(fileOutPath);
            if (fileOut.existsSync()) {
              // duplicate note item (may be different group)
              if (item.id == null) {
                logger.warning(
                    "fetchMapChanges|Item ID is null, skipping file check");
              } else {
                ModelItemFile itemFile =
                    ModelItemFile(id: item.id!, fileHash: fileName);
                await itemFile.insert();
              }
            }
          }
          // check for urls and add preview image
          if (dataMap.containsKey("url_info")) {
            Map<String, dynamic> urlInfo = dataMap["url_info"];
            String imageUrl = urlInfo["image"];
            if (item.id != null) {
              await checkDownloadNetworkImage(item.id!, imageUrl);
            } else {
              logger.warning(
                  "fetchMapChanges|Item ID is null, skipping image check");
            }
          } else {
            // remove if exists
            String fileName = '${item.id}-urlimage.png';
            File? imageFile = await getFile("image", fileName);
            if (imageFile != null && imageFile.existsSync()) {
              imageFile.deleteSync();
            }
          }
        }
    }
    SyncChangeTask changeType = SyncChangeTask.delete;
    switch (table) {
      case "category":
      case "itemgroup":
        if (hasThumbnail) {
          changeType = SyncChangeTask.fetchThumbnail;
        }
      case "item":
        ItemType? itemType = ItemTypeExtension.fromValue(map["type"]);
        switch (itemType) {
          case ItemType.document:
          case ItemType.audio:
            changeType = SyncChangeTask.fetchFile;
          case ItemType.contact:
            if (hasThumbnail) {
              changeType = SyncChangeTask.fetchThumbnail;
            }
          case ItemType.image:
          case ItemType.video:
            changeType = SyncChangeTask.fetchThumbnailFile;
          case ItemType.text:
          case ItemType.task:
          case ItemType.completedTask:
          case ItemType.location:
          case ItemType.date:
          case null:
            changeType = SyncChangeTask.delete;
        }
    }
    if (changeType.value > SyncChangeTask.delete.value) {
      await ModelChange.addUpdate(changeId, table, "", changeType.value,
          dataMap: dataMap);
      logger.info(
          "fetchChangesForTable|$table|Added change:$table|$changeId|${changeType.value}");
      await ModelChange.updateTypeState(changeId, SyncState.downloading);
    }
  }

  static Future<void> fetchMapChanges() async {
    logger.info("Fetching map changes");
    String? masterKeyBase64 = await getMasterKey();
    if (masterKeyBase64 == null) return;
    logger.info("Fetch Map Changes");
    if (simulateOnboarding()) {
      await Future.delayed(const Duration(seconds: 2));
      return;
    }
    String deviceId = await ModelPreferences.get(AppString.deviceId.string);
    Uint8List masterKeyBytes = base64Decode(masterKeyBase64);
    SodiumSumo sodium = await SodiumSumoInit.init();
    CryptoUtils cryptoUtils = CryptoUtils(sodium);
    SupabaseClient supabaseClient = Supabase.instance.client;
    String lastFetchedAt = await ModelPreferences.get(
        AppString.lastChangesFetchedAt.string,
        defaultValue: "2011-11-11 11:11:11.111111+00");
    try {
      // The cursor is taken BEFORE the request goes out.
      //
      // The server filters with `server_at > lastAt` and stamps `server_at`
      // with its own clock. A row pushed by another device *while* this batch
      // is being fetched therefore has a `server_at` between the request and
      // the moment the batch finished. Saving the local time after the batch
      // as the new cursor would skip that row forever - it would never be
      // > the cursor again. Taking the cursor up front can only cause a row
      // to be fetched twice (the upsert is idempotent), it can never lose
      // one.
      String cursorBeforeFetch = nowUtcInISO();
      // fetch public profile changes
      /* logger.info("fetch profile changes");
      final profileChanges = await supabaseClient
          .from("profiles")
          .select()
          .gt("server_at", lastFetchedAt);
      for (Map<String, dynamic> map in profileChanges) {
        ModelProfile profile = await ModelProfile.fromMap(map);
        await profile.upcertChangeFromServer();
      } */
      // fetch notes changes
      final response = await supabaseClient.functions.invoke("fetch_changes",
          headers: {"deviceId": deviceId}, body: {"lastAt": lastFetchedAt});
      Map<String, dynamic> tableChanges = jsonDecode(response.data);
      List<String> tables = ["category", "itemgroup", "item"];
      bool hadChanges = false;
      // Rows that could not be applied on the first pass. A note whose group
      // has not been created locally yet fails on the itemgroup foreign key,
      // so the failures are retried once the rest of the batch has been
      // applied.
      List<Map<String, dynamic>> failedRows = [];
      for (String table in tables) {
        if (!tableChanges.containsKey(table)) continue;
        hadChanges = true;
        List<dynamic> changesMap = tableChanges[table];
        for (Map<String, dynamic> changeMap in changesMap) {
          try {
            await applyFetchedRow(table, changeMap, masterKeyBytes, cryptoUtils);
          } catch (e, s) {
            // Never let a single bad row abort the whole batch: that used to
            // leave `lastChangesFetchedAt` untouched, so the same batch was
            // re-fetched (and failed) on every sync, forever.
            logger.error("fetchMapChanges|apply|$table|${changeMap["id"]}",
                error: e, stackTrace: s);
            failedRows.add({"table": table, "changeMap": changeMap});
          }
        }
      }
      // Second pass: the rows that failed above may have failed only because
      // their parent row (category / group) was not in the database yet.
      for (Map<String, dynamic> failed in failedRows) {
        String table = failed["table"];
        Map<String, dynamic> changeMap = failed["changeMap"];
        try {
          await applyFetchedRow(table, changeMap, masterKeyBytes, cryptoUtils);
          logger.info("fetchMapChanges|retry ok|$table|${changeMap["id"]}");
        } catch (e, s) {
          logger.error("fetchMapChanges|retry failed|$table|${changeMap["id"]}",
              error: e, stackTrace: s);
        }
      }
      // update last fetched at iso time
      if (hadChanges) {
        await ModelPreferences.set(
            AppString.lastChangesFetchedAt.string, cursorBeforeFetch);
      }
      await ModelPreferences.set(AppString.hasValidPlan.string, "yes");
      logger.info("Fetched Map Changes");
    } on FunctionException catch (e) {
      String error = "";
      try {
        dynamic details = e.details;
        Map<String, dynamic> errorMap =
            details is String ? jsonDecode(details) : details;
        error = errorMap["error"]?.toString() ?? "";
      } catch (_) {
        error = e.details?.toString() ?? "";
      }
      if (error == "Plan expired") {
        await ModelPreferences.set(AppString.hasValidPlan.string, "no");
        logger.error("fetchMapChanges|Supabase", error: "Plan Expired");
      } else {
        // Every other failure was silently swallowed here, so a broken pull
        // looked like "nothing to sync".
        logger.error("fetchMapChanges|Supabase",
            error: "FunctionException ${e.status}: $error");
      }
    } catch (e, s) {
      logger.error("fetchMapChanges|Supabase", error: e, stackTrace: s);
    }
  }

  static Future<void> fetchThumbnails() async {
    logger.info("Fetching thumbnails");
    List<ModelChange> changes = await ModelChange.requiresThumbnailFetch();
    if (changes.isEmpty) return;
    SupabaseClient supabaseClient = Supabase.instance.client;
    String? masterKeyBase64 = await getMasterKey();
    if (masterKeyBase64 == null) {
      logger.error("pushThumbnail|Master key missing");
      return;
    }
    Uint8List masterKeyBytes = base64Decode(masterKeyBase64);

    SodiumSumo sodium = await SodiumSumoInit.init();
    CryptoUtils cryptoUtils = CryptoUtils(sodium);

    for (ModelChange change in changes) {
      String changeId = change.id;
      String table = change.name;
      List<String> userIdRowId = changeId.split("|");
      String userId = userIdRowId[0];
      String rowId = userIdRowId[1];
      dynamic typedModel;
      switch (table) {
        case "category":
          typedModel = await ModelCategory.get(rowId);
        case "itemgroup":
          typedModel = await ModelGroup.get(rowId);
        case "item":
          typedModel = await ModelItem.get(rowId);
      }
      if (typedModel == null) {
        // has been deleted already
        await ModelChange.upgradeSyncTask(changeId);
        continue;
      }
      try {
        // The key material of the thumbnail. If the server has no row for
        // it, the thumbnail does not exist (the note may simply have none)
        // - advance the task instead of retrying it for ever, otherwise the
        // file behind the thumbnail is never downloaded.
        final listMap = await supabaseClient
            .from('thmbs')
            .select('cipher_nonce,key_cipher,key_nonce')
            .eq('id', changeId);
        if (listMap.isEmpty) {
          logger.warning("fetchThumbnails|no thumbnail on server|$changeId");
          await ModelChange.upgradeSyncTask(changeId);
          continue;
        }
        Uint8List encryptedThumbnailBytes = await supabaseClient.storage
            .from('thmbs')
            .download('$userId/$rowId');
        // if successfull fetch cipher keys
        Map<String, dynamic> map = listMap.first;
        map[AppString.cipherText.string] =
            base64Encode(encryptedThumbnailBytes);
        Uint8List? decryptedThumbnailBytes =
            cryptoUtils.getDecryptedBytesFromMap(map, masterKeyBytes);
        if (decryptedThumbnailBytes != null) {
          typedModel.thumbnail = decryptedThumbnailBytes;
          await typedModel.update(["thumbnail"], pushToSync: false);
          await ModelChange.upgradeSyncTask(changeId);
        }
      } on StorageException catch (e, s) {
        // The object is gone from the bucket (404): nothing to download.
        if (e.statusCode == "404") {
          logger.warning("fetchThumbnails|thumbnail not found|$changeId");
          await ModelChange.upgradeSyncTask(changeId);
        } else {
          logger.error("fetchThumbnails", error: e, stackTrace: s);
        }
      } catch (e, s) {
        logger.error("fetchThumbnails", error: e, stackTrace: s);
      }
    }
  }

  static Future<void> fetchFiles(int startedAt, bool inBackground) async {
    List<ModelChange> changes = await ModelChange.requiresFileFetch();
    if (changes.isEmpty) return;
    SodiumSumo sodium = await SodiumSumoInit.init();
    CryptoUtils cryptoUtils = CryptoUtils(sodium);
    SupabaseClient supabaseClient = Supabase.instance.client;
    String? userId = getSignedInUserId();
    if (userId == null) return;

    for (ModelChange change in changes) {
      String changeId = change.id;
      List<String> userIdRowId = changeId.split("|");
      String itemRowId = userIdRowId[1];
      ModelItem? modelItem = await ModelItem.get(itemRowId);
      if (modelItem == null) {
        logger.debug("Item deleted already, not fetching: $changeId");
        await ModelChange.upgradeSyncTask(changeId);
        continue;
      }
      Map<String, dynamic>? data = change.map;
      if (data == null) {
        // No file to download - do not leave the change stuck on this step.
        logger.warning("fetchFiles|no file data|$changeId");
        await ModelChange.upgradeSyncTask(changeId);
        continue;
      }
      String? fileName = getValueFromMap(data, "name", defaultValue: null);
      String? filePath = getValueFromMap(data, "path", defaultValue: null);
      if (fileName == null || fileName.isEmpty || filePath == null) {
        // Nothing to download - do not leave the change stuck on this step.
        logger.warning("fetchFiles|no file in the change data|$changeId");
        await ModelChange.upgradeSyncTask(changeId);
        continue;
      }
      File fileOut = File(filePath);
      if (fileOut.existsSync()) {
        // duplicate note item (may be different groups)
        logger.debug(
            "to be fetched file already exist, may be another group:$changeId");
        await ModelChange.upgradeSyncTask(changeId);
        continue;
      }
      try {
        final serverFiles = await supabaseClient
            .from("files")
            .select("uploaded_at")
            .eq("id", "$userId|$fileName")
            .maybeSingle();
        int uploadedAt = serverFiles == null
            ? 0
            : (serverFiles["uploaded_at"] as num).toInt();
        if (uploadedAt == 0) {
          logger.debug("not available to be fetched yet:$changeId");
          continue;
        }
        int fileSize = getValueFromMap(data, "size", defaultValue: 0);
        if (fileSize > 20 * 1024 * 1024) {
          // mark set downloadable
          logger.debug("Marking downloadable:$changeId");
          await ModelChange.updateTypeState(changeId, SyncState.downloadable);
          await ModelChange.upgradeSyncTask(changeId, updateState: false);
        } else {
          // download & decrypt
          bool downloadedDecrypted =
              await cryptoUtils.downloadDecryptFile(data);
          if (downloadedDecrypted) {
            await ModelChange.upgradeSyncTask(changeId);
          }
        }
      } catch (e, s) {
        logger.error("fetchFiles", error: e, stackTrace: s);
      }
    }
    logger.info("Files fetched");
  }

  static Future<bool> pushFiles(int startedAt, bool inBackground) async {
    logger.info("Push Files");
    bool hasPendingUploads = false;
    if (simulateOnboarding()) return hasPendingUploads;
    SupabaseClient supabaseClient = Supabase.instance.client;
    // push uploaded files state to supabase if left due to network failures
    // where uploadedAt > 0 but still exists,
    List<ModelFile> completedUploads = await ModelFile.pendingForPush();
    for (ModelFile completedUpload in completedUploads) {
      String fileId = completedUpload.id;
      try {
        // update if the the current uploadedAt on server is earlier than this uploadedAt
        logger.info("pushFiles|$fileId|syncing completed upload");
        await supabaseClient
            .from("files")
            .update({
              "uploaded_at": completedUpload.uploadedAt,
              "parts_uploaded": completedUpload.partsUploaded,
            })
            .eq("id", fileId)
            .lt("uploaded_at", completedUpload.uploadedAt);

        String changeId = completedUpload.changeId;
        await completedUpload
            .delete(); // deletes the encrypted file in temp dir
        // upgrade changetask
        await ModelChange.upgradeSyncTask(changeId);
      } catch (e, s) {
        logger.error("pushFiles", error: e, stackTrace: s);
      }
    }
    logger.info(
        "pushed Completed Uploads. Spent: ${DateTime.now().toUtc().millisecondsSinceEpoch - startedAt}");
    //uploading partial pending files
    // where uploadedAt = 0
    List<ModelFile> pendingUploads = await ModelFile.pendingUploads();
    for (ModelFile pendingFile in pendingUploads) {
      await pushFile(pendingFile);
      hasPendingUploads = true;
    }
    logger.info(
        "pushed Pending Uploads. Spent: ${DateTime.now().toUtc().millisecondsSinceEpoch - startedAt}");
    // upload pending files
    List<ModelChange> changes = await ModelChange.requiresFilePush();
    for (ModelChange change in changes) {
      await checkPushFile(change);
      hasPendingUploads = true;
    }
    logger.info(
        "Created New Uploads. Spent: ${DateTime.now().toUtc().millisecondsSinceEpoch - startedAt}");
    return hasPendingUploads;
  }

  static Future<void> checkPushFile(ModelChange change) async {
    SupabaseClient supabaseClient = Supabase.instance.client;
    Map<String, dynamic>? dataMap = change.map;
    if (dataMap != null) {
      List<String> userIdRowId = change.id.split("|");
      String userId = userIdRowId[0];
      String? fileIn = getValueFromMap(dataMap, "path", defaultValue: null);
      if (fileIn != null) {
        // The file name in the change data is the name the other device
        // looks the file up with - the basename of the local path can differ
        // (a renamed or restored file), and then the upload would land under
        // an id nobody looks for.
        String? nameFromData =
            getValueFromMap(dataMap, "name", defaultValue: null);
        String fileName = (nameFromData == null || nameFromData.isEmpty)
            ? path.basename(fileIn)
            : nameFromData;
        String fileId = '$userId|$fileName';
        ModelFile? existingModelFile = await ModelFile.get(fileId);
        if (existingModelFile != null) {
          logger.info("checkPushFile|modelFile exists");
          await pushFile(existingModelFile);
          return;
        }
        // check server if already uploaded (from another device)
        try {
          final serverFiles =
              await supabaseClient.from("files").select().eq("id", fileId);
          if (serverFiles.isNotEmpty) {
            // entry exist
            Map<String, dynamic> serverFile = serverFiles.first;
            int uploadedAt = (serverFile["uploaded_at"] as num).toInt();
            if (uploadedAt == 0) {
              // not uploaded
              // create new entry with server data
              serverFile["change_id"] = change.id;
              serverFile["path"] = fileIn;
              ModelFile modelFile = await ModelFile.fromMap(serverFile);
              await modelFile.insert();
              // push file
              await pushFile(modelFile);
            } else {
              // upgrade changetask
              await ModelChange.upgradeSyncTask(change.id);
            }
          } else {
            // encrypt file, get keys, update server before updating local
            Directory tempDir = await getTemporaryDirectory();
            String fileOut = path.join(tempDir.path, "$fileName.crypt");
            SodiumSumo sodium = await SodiumSumoInit.init();
            CryptoUtils cryptoUtils = CryptoUtils(sodium);
            ExecutionResult fileEncryptionResult =
                await cryptoUtils.encryptFile(fileIn, fileOut);
            if (fileEncryptionResult.isSuccess) {
              // may fail due to low storage
              var result = fileEncryptionResult.getResult();
              if (result == null) {
                logger.error("checkPushFile|Encryption result is null");
                return;
              }
              String encryptionKeyBase64 = result["key"];
              Uint8List encryptionKeyBytes = base64Decode(encryptionKeyBase64);
              String? masterKeyBase64 = await getMasterKey();
              if (masterKeyBase64 == null) {
                logger.error("checkPushFile|Master key missing");
                return;
              }
              Uint8List masterKeyBytes = base64Decode(masterKeyBase64);
              Map<String, dynamic> encryptionKeyCipher =
                  cryptoUtils.getFileEncryptionKeyCipher(
                      encryptionKeyBytes, masterKeyBytes);
              File encryptedFile = File(fileOut);
              int fileSize = encryptedFile.lengthSync();
              // Supabase Storage free tier caps uploads at 50 MB per file.
              const int maxUploadBytes = 50 * 1024 * 1024;
              if (fileSize > maxUploadBytes) {
                logger.error(
                    "checkPushFile|File too large for Supabase Storage:$fileSize");
                if (encryptedFile.existsSync()) encryptedFile.deleteSync();
                return;
              }
              String keyCipher = encryptionKeyCipher[AppString.keyCipher.string];
              String keyNonce = encryptionKeyCipher[AppString.keyNonce.string];
              // insert server row (uploaded_at = 0, parts = 1)
              await supabaseClient.from("files").insert({
                "id": fileId,
                "user_id": userId,
                "key_cipher": keyCipher,
                "key_nonce": keyNonce,
                "parts": 1,
                "size": fileSize,
              });
              // if above succeeds, create local entry
              Map<String, dynamic> fileData = {
                "id": fileId,
                "change_id": change.id,
                "path": fileIn,
                "size": fileSize,
                "key_cipher": keyCipher,
                "key_nonce": keyNonce,
                "parts": 1,
                "parts_uploaded": 0,
                "uploaded_at": 0,
              };
              ModelFile modelFile = await ModelFile.fromMap(fileData);
              await modelFile.insert();
              // start actual upload
              await pushFile(modelFile);
            } else if (fileEncryptionResult.failureReason != null &&
                fileEncryptionResult.failureReason!
                    .contains("PathNotFoundException")) {
              change.deleteWithItem();
            }
          }
        } catch (e, s) {
          logger.error("checkPushFile", error: e, stackTrace: s);
        }
      } else {
        logger.error("checkPushFile|fileIn is null");
      }
    } else {
      logger.error("checkPushFile|dataMap is null");
    }
  }

  static Future<void> pushFile(ModelFile modelFile) async {
    SupabaseClient supabaseClient = Supabase.instance.client;
    List<String> userIdFileName = modelFile.id.split("|");
    String userId = userIdFileName[0];
    String fileName = userIdFileName[1];
    try {
      logger.info("pushFile|checking server entry for: $fileName");
      final serverFiles =
          await supabaseClient.from("files").select().eq("id", modelFile.id);
      if (serverFiles.isEmpty) {
        logger.error("pushFile|no server entry for ${modelFile.id}");
        return;
      }
      Map<String, dynamic> serverFile = serverFiles.first;
      int uploadedAt = (serverFile["uploaded_at"] as num).toInt();
      if (uploadedAt > 0) {
        logger.info("pushFile|$fileName|already uploaded");
        await ModelChange.upgradeSyncTask(modelFile.changeId);
        return;
      }
      logger.info("pushFile| $fileName not uploaded");
      SodiumSumo sodium = await SodiumSumoInit.init();
      CryptoUtils cryptoUtils = CryptoUtils(sodium);
      File? fileOut = await getCreateEncryptedFileToUpload(
          modelFile.filePath, modelFile.keyCipher, modelFile.keyNonce,
          cryptoUtils);
      if (fileOut == null) {
        logger.error("pushFile|error creating encrypted file");
        return;
      }
      Uint8List bytes = await fileOut.readAsBytes();
      await supabaseClient.storage.from("media").uploadBinary(
            "$userId/$fileName",
            bytes,
            fileOptions:
                const FileOptions(upsert: true, cacheControl: "3600"),
          );
      int now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await supabaseClient.from("files").update({
        "parts_uploaded": 1,
        "uploaded_at": now,
      }).eq("id", modelFile.id).eq("uploaded_at", 0);
      modelFile.partsUploaded = 1;
      modelFile.uploadedAt = now;
      await modelFile.update(["parts_uploaded", "uploaded_at"]);
      // clean up the encrypted temp file
      if (fileOut.existsSync()) {
        fileOut.deleteSync();
      }
      await ModelChange.upgradeSyncTask(modelFile.changeId);
    } catch (e, s) {
      logger.error("pushFile", error: e, stackTrace: s);
    }
  }

  static Future<File?> getCreateEncryptedFileToUpload(
      String fileInPath,
      String keyCipherBase64,
      String keyNonceBase64,
      CryptoUtils cryptoUtils) async {
    Directory tempDir = await getTemporaryDirectory();
    String fileName = path.basename(fileInPath);
    String fileOutPath = path.join(tempDir.path, '$fileName.crypt');
    File fileOut = File(fileOutPath);
    File fileIn = File(fileInPath);
    if (!fileOut.existsSync()) {
      if (fileIn.existsSync()) {
        String? masterKeyBase64 = await getMasterKey();
        if (masterKeyBase64 == null) {
          logger.error("getCreateEncryptedFileToUpload|Master key missing");
          return null;
        }
        Uint8List masterKeyBytes = base64Decode(masterKeyBase64);
        Uint8List keyNonceBytes = base64Decode(keyNonceBase64);
        Uint8List keyCipherBytes = base64Decode(keyCipherBase64);
        ExecutionResult keyDecryptionResult = cryptoUtils.decryptBytes(
            cipherBytes: keyCipherBytes,
            nonce: keyNonceBytes,
            key: masterKeyBytes);
        if (!keyDecryptionResult.isSuccess) {
          logger.error(
              "getCreateEncryptedFileToUpload|Key decryption failed: ${keyDecryptionResult.failureReason}");
          return null;
        }
        Uint8List fileEncryptionKey =
            keyDecryptionResult.getResult()![AppString.decrypted.string];
        ExecutionResult fileEncryptionResult = await cryptoUtils
            .encryptFile(fileInPath, fileOutPath, key: fileEncryptionKey);
        if (fileEncryptionResult.isSuccess) {
          return fileOut;
        } else {
          return null;
        }
      } else {
        return null;
      }
    } else {
      return fileOut;
    }
  }

}
