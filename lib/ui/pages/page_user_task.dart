import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ntsapp/l10n/app_localizations.dart';
import 'package:ntsapp/utils/common.dart';
import 'package:ntsapp/utils/enums.dart';
import 'package:ntsapp/models/model_preferences.dart';
import 'package:ntsapp/models/model_setting.dart';
import 'package:ntsapp/services/service_logger.dart';
import 'package:ntsapp/storage/storage_secure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../common_widgets.dart';
import '../../models/model_category.dart';
import '../../models/model_profile.dart';
import 'page_access_key_input.dart';
import 'page_devices.dart';
import 'page_password_key_input.dart';
import 'page_select_key_type.dart';
import 'page_signin.dart';
import '../../utils/utils_sync.dart';

class PageUserTask extends StatefulWidget {
  final bool runningOnDesktop;
  final Function(PageType, bool, PageParams)? setShowHidePage;
  final AppTask task;
  const PageUserTask(
      {super.key,
      required this.task,
      required this.runningOnDesktop,
      this.setShowHidePage});

  @override
  State<PageUserTask> createState() => _PageUserTaskState();
}

class _PageUserTaskState extends State<PageUserTask> {
  final logger = AppLogger(prefixes: ["page_onboard_task"]);
  bool processing = true;
  SupabaseClient supabaseClient = Supabase.instance.client;

  SecureStorage secureStorage = SecureStorage();

  String taskTitle = "";
  String displayMessage = "";
  String buttonText = "";

  // keys checks
  bool fetchedFromSupabase = false;
  bool errorFetching = false;
  bool errorUpdating = false;
  bool deviceLimitExceeded = false;
  bool userIdMismatch = false;
  Map<String, dynamic>? updatedData;

  Session? currentSession = Supabase.instance.client.auth.currentSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      init(widget.task);
    });
  }

  void init(AppTask task) {
    switch (task) {
      case AppTask.registerDevice:
        registerDevice();
        break;
      case AppTask.checkEncryptionKeys:
        checkEncryptionKeys();
        break;
      case AppTask.checkCloudSync:
        checkCloudSync();
        break;
      case AppTask.signOut:
        signOut();
        break;
      case AppTask.pushLocalContent:
        pushLocalContent();
        break;
    }
  }

  Future<void> pushLocalContent() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      taskTitle = loc.encryptingNotesTitle;
      processing = true;
    });
    Timer.periodic(Duration(seconds: 1), (timer) async {
      bool pushedLocalContent = await ModelPreferences.get(
              AppString.pushedLocalContentForSync.string,
              defaultValue: "no") ==
          "yes";
      if (pushedLocalContent) {
        timer.cancel();
        if (widget.runningOnDesktop) {
          widget.setShowHidePage!(PageType.userTask, false, PageParams());
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  Future<void> checkCloudSync() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      taskTitle = loc.fetchingDetailsTitle;
      processing = true;
      errorFetching = false;
    });
    // check signed in
    bool signedIn = simulateOnboarding()
        ? ModelSetting.get(AppString.signedIn.string, "no") == "yes"
        : currentSession != null;
    String? userId = SyncUtils.getSignedInUserId();
    if (signedIn) {
      if (userId != null && !simulateOnboarding()) {
        try {
          final planResponse = await supabaseClient
              .from("plans")
              .select("expires_at")
              .eq("user_id", userId)
              .order("expires_at", ascending: false) // Get the latest plan
              .limit(1) // Ensure only one row is returned
              .maybeSingle();
          if (planResponse != null) {
            int expiresAt = int.parse(planResponse["expires_at"].toString());
            int now = DateTime.now().toUtc().millisecondsSinceEpoch;
            if (expiresAt > now) {
              await ModelPreferences.set(AppString.hasValidPlan.string, "yes");
            } else {
              await ModelPreferences.set(AppString.hasValidPlan.string, "no");
              logger.info("User signed-in but no valid plan");
            }
          }
        } catch (e) {
          logger.error("Error Fetching Plan:", error: e);
        }
      }
    } else {
      logger.info("Not signed-in");
    }
    bool deviceRegistered = await ModelPreferences.get(
            AppString.deviceRegistered.string,
            defaultValue: "no") ==
        userId;
    bool canSync = await SyncUtils.canSync();
    // set debug params
    if (simulateOnboarding()) {
      await Future.delayed(const Duration(seconds: 1));
      await ModelPreferences.set(AppString.hasValidPlan.string, "yes");
    }
    setState(() {
      processing = false;
    });
    if (!signedIn && mounted) {
      if (widget.runningOnDesktop) {
        widget.setShowHidePage!(PageType.signIn, true, PageParams());
        widget.setShowHidePage!(PageType.userTask, false, PageParams());
      } else {
        Navigator.of(context).pushReplacement(
          AnimatedPageRoute(
            child: PageSignin(
              runningOnDesktop: widget.runningOnDesktop,
              setShowHidePage: widget.setShowHidePage,
            ),
          ),
        );
      }
    } else if (!deviceRegistered) {
      registerDevice();
    } else if (!canSync || simulateOnboarding()) {
      checkEncryptionKeys();
    } else if (mounted) {
      // Attach the realtime listener and fetch right away: neither survives an
      // app restart, and waiting for the 60s polling fallback is not spontaneous.
      if (!simulateOnboarding()) {
        await SyncUtils.startRealtimeSync();
        SyncUtils.waitAndSyncChanges();
      }
      await signalToUpdateHome();
      if (mounted) {
        if (widget.runningOnDesktop) {
          widget.setShowHidePage!(PageType.userTask, false, PageParams());
        } else {
          Navigator.of(context).pop();
        }
      }
    }
  }

  Future<void> registerDevice() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      taskTitle = loc.registerDeviceTitle;
      processing = true;
      errorFetching = false;
    });
    try {
      if (simulateOnboarding()) {
        await Future.delayed(const Duration(seconds: 1));
        await ModelPreferences.set(AppString.deviceRegistered.string, "tester");
        bool canSync = await SyncUtils.canSync();
        if (!canSync) {
          checkEncryptionKeys();
        } else if (mounted) {
          if (widget.runningOnDesktop) {
            widget.setShowHidePage!(PageType.userTask, false, PageParams());
          } else {
            Navigator.of(context).pop();
          }
        }
      } else if (currentSession != null) {
        String? deviceId =
            await ModelPreferences.get(AppString.deviceId.string);
        if (deviceId == null) {
          deviceId = Uuid().v4();
          await ModelPreferences.set(AppString.deviceId.string, deviceId);
        }
        String deviceTitle = await getDeviceName();
        await supabaseClient.functions.invoke("register_device",
            body: {"deviceId": deviceId, "title": deviceTitle});
        User user = currentSession!.user;
        String userId = user.id;
        await ModelPreferences.set(AppString.deviceRegistered.string, userId);
        ModelProfile profile =
            await ModelProfile.fromMap({"id": userId, "email": user.email!});
        // if exists, update no fields.
        await profile.upcertChangeFromServer();
        // associate existing categories with this profile if not already associated
        await ModelCategory.associateWithProfile(user.id);
        bool canSync = await SyncUtils.canSync();
        if (!canSync) {
          checkEncryptionKeys();
        } else if (mounted) {
          if (widget.runningOnDesktop) {
            widget.setShowHidePage!(PageType.userTask, false, PageParams());
          } else {
            Navigator.of(context).pop();
          }
        }
      }
    } on FunctionException catch (e) {
      errorFetching = false;
      Map<String, dynamic> errorDetails =
          e.details is String ? jsonDecode(e.details) : e.details;
      displayMessage = errorDetails["error"];
      buttonText = loc.continueLabel;
      if (displayMessage.contains("limit")) {
        deviceLimitExceeded = true;
        buttonText = loc.manageButtonLabel;
      }
    } catch (e, s) {
      logger.error("registerDevice", error: e, stackTrace: s);
      setState(() {
        errorFetching = true;
        displayMessage = loc.couldNotFetchMessage;
        buttonText = loc.retryButtonLabel;
      });
    }
    setState(() {
      processing = false;
    });
  }

  Future<void> checkEncryptionKeys() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      taskTitle = loc.fetchingKeysTitle;
      processing = true;
      errorFetching = false;
    });
    if (simulateOnboarding()) {
      await Future.delayed(const Duration(seconds: 1));
    }
    String? userId = SyncUtils.getSignedInUserId();
    if (userId == null && !simulateOnboarding()) return;
    //check where to navigate
    try {
      List<Map<String, dynamic>> keyRows = [];
      if (simulateOnboarding()) {
        if (await ModelPreferences.get(AppString.hasEncryptionKeys.string,
                defaultValue: "no") ==
            "yes") {
          keyRows = [
            jsonDecode(
                await ModelPreferences.get(AppString.debugCipherData.string))
          ];
        }
      } else {
        keyRows = await supabaseClient.from("keys").select().eq("id", userId!);
      }
      if (keyRows.isEmpty && mounted) {
        if (widget.runningOnDesktop) {
          widget.setShowHidePage!(PageType.selectKeyType, true, PageParams());
          widget.setShowHidePage!(PageType.userTask, false, PageParams());
        } else {
          Navigator.of(context).pushReplacement(
            AnimatedPageRoute(
              child: PageSelectKeyType(
                runningOnDesktop: widget.runningOnDesktop,
                setShowHidePage: widget.setShowHidePage,
              ),
            ),
          );
        }
      } else if (mounted) {
        Map<String, dynamic> keyRow = keyRows.first;
        if (keyRow["salt"] != null) {
          if (widget.runningOnDesktop) {
            widget.setShowHidePage!(
                PageType.passwordInput, true, PageParams(cipherData: keyRow));
            widget.setShowHidePage!(PageType.userTask, false, PageParams());
          } else {
            Navigator.of(context).pushReplacement(
              AnimatedPageRoute(
                child: PagePasswordKeyInput(
                  runningOnDesktop: widget.runningOnDesktop,
                  setShowHidePage: widget.setShowHidePage,
                  cipherData: keyRow,
                ),
              ),
            );
          }
        } else {
          if (widget.runningOnDesktop) {
            widget.setShowHidePage!(
                PageType.accessKeyInput, true, PageParams(cipherData: keyRow));
            widget.setShowHidePage!(PageType.userTask, false, PageParams());
          } else {
            Navigator.of(context).pushReplacement(
              AnimatedPageRoute(
                child: PageAccessKeyInput(
                  cipherData: keyRow,
                  runningOnDesktop: widget.runningOnDesktop,
                  setShowHidePage: widget.setShowHidePage,
                ),
              ),
            );
          }
        }
      }
    } catch (e, s) {
      logger.error("navigateAfterRegistering", error: e, stackTrace: s);
      setState(() {
        errorFetching = true;
        displayMessage = loc.couldNotFetchMessage;
        buttonText = loc.retryButtonLabel;
      });
    }
    setState(() {
      processing = false;
    });
  }

  Future<void> signOut() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      processing = true;
      errorFetching = false;
      taskTitle = loc.signingOutTitle;
    });
    // check internet
    bool hasInternet = await hasInternetConnection();
    if (!hasInternet && mounted) {
      setState(() {
        errorFetching = true;
        processing = false;
        displayMessage = loc.pleaseCheckInternetMessage;
        buttonText = loc.retryButtonLabel;
      });
    }
    bool success = await SyncUtils.signout();
    if (success && mounted) {
      if (widget.runningOnDesktop) {
        widget.setShowHidePage!(PageType.userTask, false, PageParams());
        widget.setShowHidePage!(PageType.planStatus, false, PageParams());
      } else {
        Navigator.of(context).pop();
      }
    } else {
      setState(() {
        errorFetching = true;
        processing = false;
        displayMessage = loc.somethingWentWrongMessage;
        buttonText = loc.retryButtonLabel;
      });
    }
  }

  Future<void> takeAction() async {
    if (errorFetching) {
      displayMessage = "";
      buttonText = "";
      switch (widget.task) {
        case AppTask.registerDevice:
          registerDevice();
          break;
        case AppTask.checkEncryptionKeys:
          checkEncryptionKeys();
          break;
        case AppTask.checkCloudSync:
          checkCloudSync();
          break;
        case AppTask.signOut:
          break;
        case AppTask.pushLocalContent:
          break;
      }
    } else if (deviceLimitExceeded) {
      if (widget.runningOnDesktop) {
        widget.setShowHidePage!(PageType.devices, true, PageParams());
        widget.setShowHidePage!(PageType.userTask, false, PageParams());
      } else {
        Navigator.of(context).pushReplacement(
          AnimatedPageRoute(
            child: PageDevices(
              runningOnDesktop: widget.runningOnDesktop,
              setShowHidePage: widget.setShowHidePage,
            ),
          ),
        );
      }
    } else if (userIdMismatch) {
      await supabaseClient.auth.signOut();
      if (widget.runningOnDesktop) {
        widget.setShowHidePage!(PageType.userTask, false, PageParams());
      } else {
        if (mounted) Navigator.of(context).pop();
      }
    } else if (displayMessage.isNotEmpty) {
      if (widget.runningOnDesktop) {
        widget.setShowHidePage!(PageType.userTask, false, PageParams());
      } else {
        if (mounted) Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(taskTitle),
          leading: widget.runningOnDesktop
              ? BackButton(
                  onPressed: () {
                    widget.setShowHidePage!(
                        PageType.userTask, false, PageParams());
                  },
                )
              : null,
        ),
        body: processing
            ? Center(
                child: CircularProgressIndicator(),
              )
            : Center(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        displayMessage,
                        style: TextStyle(fontSize: 15),
                      ),
                    ),
                    SizedBox(
                      height: 30,
                    ),
                    buttonText.isEmpty
                        ? const SizedBox.shrink()
                        : ElevatedButton(
                            onPressed: takeAction,
                            child: Text(
                              buttonText,
                              style: TextStyle(color: Colors.black),
                            ))
                  ],
                ),
              ));
  }
}
