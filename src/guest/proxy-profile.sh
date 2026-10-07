# The Mac's proxy when this VM was built (OmacVM, #232), for the network the
# VM is on now (omacvm-proxy-env, from guest/install.sh). Delete
# /etc/omacvm/proxy.env to stop using it.
if [ -x /usr/local/bin/omacvm-proxy-env ]; then
  _omacvm_proxy=$(/usr/local/bin/omacvm-proxy-env 2>/dev/null)
  while IFS= read -r _omacvm_l; do
    # shellcheck disable=SC2163  # the line is NAME=VALUE
    case $_omacvm_l in [A-Za-z_]*=*) export "$_omacvm_l" ;; esac
  done <<OMACVM_PROXY
$_omacvm_proxy
OMACVM_PROXY
  unset _omacvm_proxy _omacvm_l
fi
