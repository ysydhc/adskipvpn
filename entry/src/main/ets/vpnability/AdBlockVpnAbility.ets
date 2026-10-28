import { VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnAdBlockEngine } from '../vpn/VpnAdBlockEngine';

const TAG = 'AdBlockVpnAbility';
const DOMAIN = 0x0001;

/**
 * 系统托管的 VPN 扩展能力组件 (type: "vpn")
 */
export default class AdBlockVpnAbility extends VpnExtensionAbility {
  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'AdBlockVpnAbility onCreate, want: %{public}s', JSON.stringify(want));
    VpnAdBlockEngine.getInstance()
      .start(this.context)
      .then((tunFd: number) => {
        hilog.info(DOMAIN, TAG, 'VPN 引擎启动成功, tunFd=%{public}d', tunFd);
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'VPN 引擎启动失败: %{public}s', err.message);
      });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'AdBlockVpnAbility onDestroy');
    VpnAdBlockEngine.getInstance().stop();
  }
}
