# zforge: make the `zforge` command available in login shells.
# Installed as /etc/profile.d/zforge.sh (sourced by the stock /etc/profile).
case ":$PATH:" in
    *:/data/.zforge/bin:*) ;;
    *) PATH="$PATH:/data/.zforge/bin" ;;
esac
export PATH
