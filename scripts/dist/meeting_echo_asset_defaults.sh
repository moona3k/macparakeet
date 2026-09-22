# Shared release defaults for bundled meeting echo-suppression assets.
# Sourced by build_app_bundle.sh and prepare_meeting_echo_assets.sh; not executed directly.

DEFAULT_MEETING_ECHO_MODEL_NAME="localvqe-v1.4-aec-200K-f32.gguf"
DEFAULT_MEETING_ECHO_MODEL_SHA256="b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"

# Single source of truth for the app's minimum macOS version, shared by
# build_app_bundle.sh's MIN_MACOS_VERSION default, the LocalVQE runtime's
# CMAKE_OSX_DEPLOYMENT_TARGET, and the bundle verifier's rejection ceiling.
DEFAULT_MEETING_ECHO_MIN_MACOS_VERSION="14.2"
