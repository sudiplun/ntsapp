import 'package:flutter/material.dart';
import 'package:ntsapp/l10n/app_localizations.dart';
import 'package:ntsapp/ui/common_widgets.dart';
import 'package:ntsapp/models/model_preferences.dart';
import 'package:ntsapp/models/model_setting.dart';
import 'package:ntsapp/ui/pages/page_user_task.dart';
import 'package:ntsapp/services/service_logger.dart';
import 'package:ntsapp/storage/storage_secure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../utils/common.dart';
import '../../utils/enums.dart';

class PageSignin extends StatefulWidget {
  final bool runningOnDesktop;
  final Function(PageType, bool, PageParams)? setShowHidePage;
  const PageSignin(
      {super.key, required this.runningOnDesktop, this.setShowHidePage});

  @override
  State<PageSignin> createState() => _PageSigninState();
}

class _PageSigninState extends State<PageSignin> {
  final logger = AppLogger(prefixes: ["page_signin"]);
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  SecureStorage storage = SecureStorage();
  bool processing = false;
  bool isCreateAccount = false;
  final SupabaseClient supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    emailController.text = ModelSetting.get(AppString.signedInEmail.string, "");
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  // cases: First time (create account), Re-login (sign in)
  Future<void> proceed() async {
    final loc = AppLocalizations.of(context)!;
    if (processing) return;
    final email = emailController.text.trim();
    final password = passwordController.text.trim();
    if (email.isEmpty || !email.contains("@")) {
      displaySnackBar(context, message: loc.enterEmailLabel, seconds: 2);
      return;
    }
    if (password.length < 8) {
      displaySnackBar(context,
          message: loc.passwordTooShortMessage, seconds: 2);
      return;
    }
    if (isCreateAccount && confirmPasswordController.text.trim() != password) {
      displaySnackBar(context,
          message: loc.passwordsDoNotMatchMessage, seconds: 2);
      return;
    }
    setState(() {
      processing = true;
    });
    // Simulated onboarding user
    if (email == 'tester@notesafe.app') {
      await Future.delayed(const Duration(seconds: 1));
      await ModelSetting.set(AppString.simulateTesting.string, "yes");
      await ModelSetting.delete(AppString.otpSentAt.string);
      await ModelSetting.delete(AppString.otpSentTo.string);
      await ModelSetting.set(AppString.signedInEmail.string, email);
      await ModelSetting.set(AppString.signedIn.string, "yes");
      if (mounted) {
        setState(() {
          processing = false;
        });
        await navigateToOnboardCheck();
      }
      return;
    }
    try {
      if (isCreateAccount) {
        AuthResponse response =
            await supabase.auth.signUp(email: email, password: password);
        if (response.session == null) {
          // happens if "Confirm email" got turned back on in the dashboard:
          // no session until the confirmation email link is used.
          logger.warning("signup|no session returned - confirm email is on?");
          if (mounted) {
            displaySnackBar(context,
                message: loc.somethingWentWrongMessage, seconds: 3);
          }
          return;
        }
        logger.info("Signed up");
      } else {
        await supabase.auth
            .signInWithPassword(email: email, password: password);
        logger.info("Signed in");
      }
      await ModelSetting.delete(AppString.otpSentAt.string);
      await ModelSetting.delete(AppString.otpSentTo.string);
      await ModelSetting.set(AppString.signedInEmail.string, email);
      await ModelSetting.set(AppString.signedIn.string, "yes");
      String? existingDeviceId =
          await ModelPreferences.get(AppString.deviceId.string);
      if (existingDeviceId == null) {
        String newDeviceId = Uuid().v4();
        await ModelPreferences.set(AppString.deviceId.string, newDeviceId);
      }
      if (mounted) {
        await navigateToOnboardCheck();
      }
    } on AuthException catch (e, s) {
      logger.error("Proceed-auth", error: e, stackTrace: s);
      String message = e.message.toLowerCase();
      String displayMessage = loc.somethingWentWrongMessage;
      if (isCreateAccount) {
        if (message.contains("already registered") ||
            message.contains("user_already_exists")) {
          displayMessage = loc.accountExistsMessage;
        } else if (message.contains("weak_password") ||
            message.contains("password should be")) {
          displayMessage = loc.passwordTooShortMessage;
        }
      } else {
        if (message.contains("invalid login credentials")) {
          displayMessage = loc.invalidCredentialsMessage;
        } else if (message.contains("rate limit") ||
            message.contains("too many requests")) {
          displayMessage = loc.tooManyAttemptsMessage;
        }
      }
      if (mounted) {
        displaySnackBar(context, message: displayMessage, seconds: 3);
      }
    } catch (e, s) {
      logger.error("Proceed", error: e, stackTrace: s);
      if (mounted) {
        displaySnackBar(context,
            message: loc.somethingWentWrongMessage, seconds: 2);
      }
    }
    if (mounted) {
      setState(() {
        processing = false;
      });
    }
  }

  Future<void> navigateToOnboardCheck() async {
    setState(() {
      processing = false;
    });
    if (widget.runningOnDesktop) {
      widget.setShowHidePage!(
          PageType.userTask, true, PageParams(appTask: AppTask.checkCloudSync));
      widget.setShowHidePage!(PageType.signIn, false, PageParams());
    } else {
      Navigator.of(context).pushReplacement(
        AnimatedPageRoute(
          child: PageUserTask(
            runningOnDesktop: widget.runningOnDesktop,
            setShowHidePage: widget.setShowHidePage,
            task: AppTask.checkCloudSync,
          ),
        ),
      );
    }
  }

  Future<void> changeMode() async {
    setState(() {
      isCreateAccount = !isCreateAccount;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(isCreateAccount
            ? loc.createAccountButtonLabel
            : loc.emailSignInTitle),
        leading: widget.runningOnDesktop
            ? BackButton(
                onPressed: () {
                  widget.setShowHidePage!(PageType.signIn, false, PageParams());
                },
              )
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                TextField(
                  autofocus: true,
                  controller: emailController,
                  decoration: InputDecoration(labelText: loc.enterEmailLabel),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  decoration:
                      InputDecoration(labelText: loc.enterPasswordLabel),
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: isCreateAccount
                      ? TextInputAction.next
                      : TextInputAction.done,
                  onSubmitted: (text) {
                    if (!isCreateAccount) proceed();
                  },
                ),
                if (isCreateAccount) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmPasswordController,
                    decoration:
                        InputDecoration(labelText: loc.confirmPasswordLabel),
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (text) {
                      proceed();
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(loc.emailPasswordNote),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: proceed,
                    child: processing
                        ? const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            ),
                          )
                        : Text(
                            isCreateAccount
                                ? loc.createAccountButtonLabel
                                : loc.signInButtonLabel,
                            style: const TextStyle(color: Colors.black),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: changeMode,
                  child: Text(isCreateAccount
                      ? loc.alreadyHaveAccountLabel
                      : loc.createAccountButtonLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
