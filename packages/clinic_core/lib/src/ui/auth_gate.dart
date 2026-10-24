import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/models.dart';
import 'common.dart';
import 'login_screens.dart';

/// Routes between loading, the sign-in flow and the app itself based on [AuthController.state].
class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.controller,
    required this.appName,
    this.tagline,
    required this.signedInBuilder,
  });

  final AuthController controller;
  final String appName;
  final String? tagline;
  final Widget Function(BuildContext context, Me me) signedInBuilder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        switch (controller.state) {
          case AuthState.loading:
            return const Scaffold(body: LoadingView());
          case AuthState.signedOut:
            return LoginFlow(controller: controller, appName: appName, tagline: tagline);
          case AuthState.needsMfa:
            return MfaChallengeScreen(controller: controller);
          case AuthState.signedIn:
            return signedInBuilder(context, controller.me!);
        }
      },
    );
  }
}

/// Phone -> OTP steps (the MFA step is driven by the controller state).
class LoginFlow extends StatefulWidget {
  const LoginFlow({super.key, required this.controller, required this.appName, this.tagline});
  final AuthController controller;
  final String appName;
  final String? tagline;

  @override
  State<LoginFlow> createState() => _LoginFlowState();
}

class _LoginFlowState extends State<LoginFlow> {
  String? _phone;
  String? _devCode;

  @override
  Widget build(BuildContext context) {
    if (_phone != null) {
      return OtpScreen(
        controller: widget.controller,
        phone: _phone!,
        devCode: _devCode,
        onBack: () => setState(() => _phone = null),
      );
    }
    return PhoneLoginScreen(
      controller: widget.controller,
      appName: widget.appName,
      tagline: widget.tagline,
      notice: widget.controller.bootstrapError,
      onCodeSent: (phone, dev) => setState(() {
        _phone = phone;
        _devCode = dev;
      }),
    );
  }
}
