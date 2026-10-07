# The test identity of an OmacVM.app copy, from its Info.plist. Sourced by
# omacvm (the app's own copy) and app/scripts/vm-common.sh; macOS's bash 3.2.
#
# app_test_identity CONTENTS (<app>/Contents): when OMACVM_TEST_IDENTITY is
# not set and the app is "OmacVM Test" (org.omacvm.app.test) or a lane's copy
# of it (org.omacvm.app.test.<lane>, as the app's TestIdentity.isTest), exports
# OMACVM_TEST_IDENTITY=1. Else nothing changes. A script of the test app run
# by hand is then the test identity too, not only when the app sets it: else
# it installs the normal helpers next to the test ones.
app_test_identity() {
  [[ -z ${OMACVM_TEST_IDENTITY:-} && -f $1/Info.plist ]] || return 0
  local id
  id=$(plutil -extract CFBundleIdentifier raw -o - "$1/Info.plist" 2>/dev/null) || return 0
  case $id in
    org.omacvm.app.test|org.omacvm.app.test.*) export OMACVM_TEST_IDENTITY=1 ;;
  esac
  return 0
}
