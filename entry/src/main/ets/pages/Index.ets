import { vpnExtension, connection } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { AdDomainRules } from '../vpn/AdDomainRules';
import { VPN_LOG_EVENT, VPN_CMD_EVENT, VPN_TRACE_LOG_FILE } from '../vpn/VpnAdBlockEngine';
import { TargetAppsManager, TargetAppItem, SkipMode, TargetAppsConfig, CustomProbeRule, AppSkipStrategy } from '../utils/TargetAppsManager';
import adskipBridge from 'libadskip_bridge.so';

const ADSKIP_LOG_FILE: string = '/adskip_skip.log';

interface LocalSkipDaemonStatus {
  running: boolean;
  enabled: boolean;
  skippedCount: number;
  pid?: number;
}

@Entry
@Component
struct Index {
  // 顶部导航切换：0 = ⚡ 自动点击跳过 | 1 = 🛡️ VPN 域名过滤
  @State activeTab: number = 0;

  // ====== 自动点击跳过状态 ======
  @State daemonRunning: boolean = false;
  @State daemonEnabled: boolean = true;
  @State daemonPid: number = 0;
  @State accessibilityEnabled: boolean = false;
  @State skippedCount: number = 0;
  @State skipLogs: string[] = [
    '[READY] ⚡ 开屏广告自动跳过服务已就绪',
    '[RULE] 智能识别开屏「跳过 / 跳过广告 / 关闭广告」控件并执行触控'
  ];

  // ====== 目标跳过应用管理状态 ======
  @State targetConfig: TargetAppsConfig = { mode: 'TARGETS_ONLY', apps: [] };
  @State showTargetAppsPanel: boolean = false;
  @State newAppName: string = '';
  @State newAppBundle: string = '';
  // 独立跳过策略与探针参数调节状态
  @State editingProbeApp: TargetAppItem | null = null;
  @State editStrategy: AppSkipStrategy = 'AUTO';
  @State editDelayMs: string = '200';
  @State editCoordX: string = '1135';
  @State editCoordY: string = '185';
  @State editRepeatTimes: string = '4';
  @State editProbeEnabled: boolean = true;

  // ====== VPN 域名过滤状态 ======
  @State vpnRunning: boolean = false;
  @State blockedCount: number = 0;
  @State watchCount: number = 0;
  @State allowedCount: number = 0;
  @State ruleCount: number = AdDomainRules.getAllRules().length;
  @State filterMode: string = 'ALL'; // ALL | BLOCK | WATCH | ALLOW
  @State showSpecialDebug: boolean = false; // 特殊应用调试面板折叠开关
  @State vpnLogs: string[] = [
    '[READY] 🛡️ 本地 VPN 广告域名过滤服务已就绪',
    `[RULES] 已加载广告域名拦截规则 ${AdDomainRules.getAllRules().length} 条`
  ];
  @State customDomain: string = '';

  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private skipScroller: ListScroller = new ListScroller();
  private vpnScroller: ListScroller = new ListScroller();
  private daemonPollTimer: number = -1;
  private lastSkipLogSize: number = -1;

  aboutToAppear(): void {
    adskipBridge.initBridge();
    this.daemonEnabled = adskipBridge.getDaemonEnabled();
    const context = getContext(this) as common.UIAbilityContext;
    AdDomainRules.syncCustomRulesFromDisk(context.filesDir);
    this.ruleCount = AdDomainRules.getAllRules().length;
    this.loadTargetAppsConfig();
    this.extractBundledDaemonBinary();
    this.refreshAccessibilityStatus();
    this.reloadSkipLogs();
    this.reloadVpnLogs();
    this.subscribeEvents();
    this.syncLocalSkipDaemon('/status');
    this.daemonPollTimer = setInterval(() => {
      this.syncLocalSkipDaemon('/status');
    }, 1200);
  }

  onPageShow(): void {
    const context = getContext(this) as common.UIAbilityContext;
    AdDomainRules.syncCustomRulesFromDisk(context.filesDir);
    this.ruleCount = AdDomainRules.getAllRules().length;
    this.loadTargetAppsConfig();
    this.refreshAccessibilityStatus();
    this.reloadSkipLogs();
    this.reloadVpnLogs();
    this.syncLocalSkipDaemon('/status');
    this.sendVpnCommand('STATUS');
  }

  aboutToDisappear(): void {
    if (this.subscriber !== null) {
      commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = null;
    }
    if (this.daemonPollTimer !== -1) {
      clearInterval(this.daemonPollTimer);
      this.daemonPollTimer = -1;
    }
  }

  /**
   * 释放内置自动跳过守护脚本到应用沙箱目录
   */
  private extractBundledDaemonBinary(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const scriptPath = context.filesDir + '/adskip_daemon.sh';
      const rawScript = context.resourceManager.getRawFileContentSync('adskip_daemon.sh');
      const sFile = fileIo.openSync(scriptPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(sFile.fd, rawScript.buffer);
      fileIo.closeSync(sFile);
    } catch (_) {
    }
  }

  /**
   * 同步自动跳过守护服务状态与跳过日志
   */
  private syncLocalSkipDaemon(action: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const statusPath = context.filesDir + '/adskip_status.json';
      const skipLogPath = context.filesDir + ADSKIP_LOG_FILE;

      if (action === '/enable') {
        adskipBridge.setDaemonEnabled(true);
        this.daemonEnabled = true;
        this.appendSkipLog('[SKIP-SVC] ✅ 已开启并重置开屏广告自动跳过服务');
        setTimeout(() => {
          this.syncLocalSkipDaemon('/status');
          this.reloadSkipLogs();
        }, 600);
      } else if (action === '/restart') {
        adskipBridge.setDaemonEnabled(true);
        this.daemonEnabled = true;
        this.appendSkipLog('[SKIP-SVC] 🔄 正在重置并重启后台自动跳过引擎...');
        setTimeout(() => {
          this.syncLocalSkipDaemon('/status');
          this.reloadSkipLogs();
        }, 600);
      } else if (action === '/disable') {
        adskipBridge.setDaemonEnabled(false);
        this.daemonEnabled = false;
        this.appendSkipLog('[SKIP-SVC] ⏸️ 已暂停开屏广告自动跳过服务');
      }

      if (fileIo.accessSync(statusPath)) {
        const raw = fileIo.readTextSync(statusPath).trim();
        if (raw.length > 0) {
          const data = JSON.parse(raw) as LocalSkipDaemonStatus;
          this.daemonRunning = Boolean(data.running);
          this.daemonEnabled = adskipBridge.getDaemonEnabled();
          if (data.pid && data.pid > 0) {
            this.daemonPid = data.pid;
          }
          if (typeof data.skippedCount === 'number' && data.skippedCount > this.skippedCount) {
            this.skippedCount = data.skippedCount;
            this.reloadSkipLogs();
          }
        }
      }

      if (fileIo.accessSync(skipLogPath)) {
        const curSize = fileIo.statSync(skipLogPath).size;
        if (curSize !== this.lastSkipLogSize) {
          this.lastSkipLogSize = curSize;
          this.reloadSkipLogs();
        }
      }
    } catch (_) {
    }
  }

  /**
   * 切换自动跳过开关状态
   */
  private setAutoSkipEnabled(nextEnabled: boolean): void {
    if (nextEnabled === this.daemonEnabled) {
      return;
    }
    this.syncLocalSkipDaemon(nextEnabled ? '/enable' : '/disable');
  }

  private toggleLocalSkipDaemon(): void {
    this.setAutoSkipEnabled(!this.daemonEnabled);
  }

  private refreshAccessibilityStatus(): void {
    try {
      const enabledList = accessibility.getAccessibilityExtensionListSync('all', 'enable');
      const isEnabled = enabledList.some(
        (info: accessibility.AccessibilityAbilityInfo) =>
          info.bundleName === 'com.ysydhc.adskipvpn' || info.name === 'AdSkipAccessibilityAbility'
      );
      this.accessibilityEnabled = isEnabled;
    } catch (_) {
      this.accessibilityEnabled = false;
    }
  }

  /**
   * 目标跳过应用管理相关逻辑
   */
  private loadTargetAppsConfig(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.loadConfig(context.filesDir);
    } catch (_) {
    }
  }

  private toggleTargetApp(bundleName: string, enabled: boolean): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.toggleApp(context.filesDir, bundleName, enabled);
    } catch (_) {
    }
  }

  private setSkipMode(mode: SkipMode): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.setMode(context.filesDir, mode);
    } catch (_) {
    }
  }

  private addCustomTargetApp(): void {
    const bundle = this.newAppBundle.trim();
    if (bundle.length === 0) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.addApp(context.filesDir, this.newAppName, bundle);
      this.newAppName = '';
      this.newAppBundle = '';
    } catch (_) {
    }
  }

  private openProbeRuleEditor(item: TargetAppItem): void {
    this.editingProbeApp = item;
    if (item.probeRule) {
      this.editStrategy = item.probeRule.strategy || (item.probeRule.enabled ? 'PROBE' : 'AUTO');
      this.editDelayMs = item.probeRule.delayMs.toString();
      this.editCoordX = item.probeRule.coordX.toString();
      this.editCoordY = item.probeRule.coordY.toString();
      this.editRepeatTimes = (item.probeRule.repeatTimes || 4).toString();
      this.editProbeEnabled = item.probeRule.enabled;
    } else {
      this.editStrategy = 'AUTO';
      this.editDelayMs = '200';
      this.editCoordX = '1135';
      this.editCoordY = '185';
      this.editRepeatTimes = '4';
      this.editProbeEnabled = true;
    }
  }

  private saveCurrentProbeRule(): void {
    if (!this.editingProbeApp) {
      return;
    }
    const delay = parseInt(this.editDelayMs.trim(), 10) || 0;
    const cx = parseInt(this.editCoordX.trim(), 10) || 1135;
    const cy = parseInt(this.editCoordY.trim(), 10) || 185;
    const repeat = Math.max(1, Math.min(5, parseInt(this.editRepeatTimes.trim(), 10) || 4));
    const newRule: CustomProbeRule = {
      enabled: this.editStrategy !== 'DISABLED',
      strategy: this.editStrategy,
      delayMs: Math.max(0, Math.min(10000, delay)),
      coordX: cx,
      coordY: cy,
      repeatTimes: repeat
    };
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.updateProbeRule(context.filesDir, this.editingProbeApp.bundleName, newRule);
      this.appendSkipLog(`[CONFIG] 已更新【${this.editingProbeApp.name}】策略: 方式=${this.editStrategy} 延迟=${newRule.delayMs}ms 坐标=(${newRule.coordX},${newRule.coordY}) 次数=${newRule.repeatTimes}次`);
    } catch (_) {
    }
    this.editingProbeApp = null;
  }

  private removeTargetApp(bundleName: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.removeApp(context.filesDir, bundleName);
    } catch (_) {
    }
  }

  private resetTargetAppsToDefault(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.targetConfig = TargetAppsManager.resetToDefault(context.filesDir);
    } catch (_) {
    }
  }

  private batchToggleAllTargetApps(enable: boolean): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const cfg = TargetAppsManager.loadConfig(context.filesDir);
      for (const item of cfg.apps) {
        item.enabled = enable;
      }
      TargetAppsManager.saveConfig(context.filesDir, cfg);
      this.targetConfig = cfg;
    } catch (_) {
    }
  }

  private getEnabledTargetAppsCount(): number {
    if (!this.targetConfig || !this.targetConfig.apps) {
      return 0;
    }
    return this.targetConfig.apps.filter((item: TargetAppItem) => item.enabled).length;
  }

  /**
   * 读取自动点击跳过日志 (adskip_skip.log)
   */
  private reloadSkipLogs(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + ADSKIP_LOG_FILE;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const content = fileIo.readTextSync(path);
      const rawLines = content.split('\n').filter((line: string) => line.trim().length > 0);
      if (rawLines.length === 0) {
        return;
      }
      let sCount = 0;
      for (const line of rawLines) {
        if (line.includes('[SKIP]')) {
          sCount += 1;
        }
      }
      if (sCount > this.skippedCount) {
        this.skippedCount = sCount;
      }
      this.skipLogs = rawLines.reverse().slice(0, 200);
      this.skipScroller.scrollToIndex(0);
    } catch (_) {
    }
  }

  /**
   * 读取 VPN 域名过滤日志 (vpn_dns_trace.log)
   */
  private reloadVpnLogs(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + VPN_TRACE_LOG_FILE;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const content = fileIo.readTextSync(path);
      const rawLines = content
        .split('\n')
        .filter((line: string) => line.trim().length > 0 && !line.includes('[SKIP]') && !line.includes('[SKIP-SVC]'));
      if (rawLines.length === 0) {
        return;
      }

      let bCount = 0;
      let wCount = 0;
      let aCount = 0;
      let running = this.vpnRunning;

      for (const line of rawLines) {
        if (line.includes('[BLOCK]')) {
          bCount += 1;
        } else if (line.includes('[WATCH]') && !line.includes('[解析完成]')) {
          wCount += 1;
        } else if (line.includes('[ALLOW]')) {
          aCount += 1;
        } else if (line.includes('[START]') || line.includes('运行中=true')) {
          running = true;
        } else if (line.includes('[STOP]')) {
          running = false;
        }
      }

      this.blockedCount = bCount;
      this.watchCount = wCount;
      this.allowedCount = aCount;
      this.vpnRunning = running;
      this.vpnLogs = rawLines.reverse().slice(0, 200);
      this.vpnScroller.scrollToIndex(0);
    } catch (_) {
    }
  }

  /**
   * 订阅跨进程事件，将自动跳过日志与 VPN 抓包日志分别路由到对应视图
   */
  private subscribeEvents(): void {
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [VPN_LOG_EVENT]
    };
    commonEventManager.createSubscriber(subscribeInfo).then((sub: commonEventManager.CommonEventSubscriber) => {
      this.subscriber = sub;
      commonEventManager.subscribe(sub, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (!err && data && data.data) {
          const msg = data.data;
          if (msg.includes('[SKIP]') || msg.includes('[SKIP-SVC]')) {
            if (msg.includes('[SKIP]')) {
              this.skippedCount += 1;
            }
            this.skipLogs = [msg, ...this.skipLogs].slice(0, 200);
            return;
          }
          if (msg.includes('[BLOCK]')) {
            this.blockedCount += 1;
          } else if (msg.includes('[WATCH]') && !msg.includes('[解析完成]')) {
            this.watchCount += 1;
          } else if (msg.includes('[ALLOW]')) {
            this.allowedCount += 1;
          } else if (msg.includes('[START]') || msg.includes('运行中=true')) {
            this.vpnRunning = true;
          } else if (msg.includes('[STOP]')) {
            this.vpnRunning = false;
          }
          this.vpnLogs = [msg, ...this.vpnLogs].slice(0, 200);
        }
      });
    }).catch(() => {
    });
  }

  private sendVpnCommand(cmd: string): void {
    try {
      commonEventManager.publish(VPN_CMD_EVENT, { data: cmd }, () => {});
    } catch (_) {
    }
  }

  private formatTimestamp(): string {
    const now = new Date();
    return (
      `${now.getHours().toString().padStart(2, '0')}:` +
      `${now.getMinutes().toString().padStart(2, '0')}:` +
      `${now.getSeconds().toString().padStart(2, '0')}.` +
      `${now.getMilliseconds().toString().padStart(3, '0')}`
    );
  }

  private appendSkipLog(line: string): void {
    const fullLine = `${this.formatTimestamp()} ${line}`;
    this.skipLogs = [fullLine, ...this.skipLogs].slice(0, 200);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + ADSKIP_LOG_FILE;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${fullLine}\n`);
      fileIo.closeSync(file);
    } catch (_) {
    }
  }

  private appendVpnLog(line: string): void {
    const fullLine = `${this.formatTimestamp()} ${line}`;
    this.vpnLogs = [fullLine, ...this.vpnLogs].slice(0, 200);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + VPN_TRACE_LOG_FILE;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${fullLine}\n`);
      fileIo.closeSync(file);
    } catch (_) {
    }
  }

  private clearSkipLogs(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + ADSKIP_LOG_FILE;
      if (fileIo.accessSync(path)) {
        const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.closeSync(f);
      }
    } catch (_) {
    }
    this.skippedCount = 0;
    this.skipLogs = [];
    this.appendSkipLog('[CLEAR] 已清空自动跳过历史记录');
  }

  private clearVpnLogs(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = context.filesDir + VPN_TRACE_LOG_FILE;
      if (fileIo.accessSync(path)) {
        const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.closeSync(f);
      }
    } catch (_) {
    }
    this.blockedCount = 0;
    this.watchCount = 0;
    this.allowedCount = 0;
    this.vpnLogs = [];
    this.appendVpnLog('[CLEAR] 已清空 VPN DNS 抓包日志');
  }

  private async startVpn(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'AdBlockVpnAbility'
    };
    this.appendVpnLog(`[ACTION] 正在启动本地 VPN 过滤服务 (${want.bundleName})...`);
    try {
      await vpnExtension.startVpnExtensionAbility(want);
      this.vpnRunning = true;
      this.appendVpnLog('[SUCCESS] 本地 VPN 虚拟网卡隧道已激活');
      this.sendVpnCommand('STATUS');
    } catch (err) {
      const error = err as BusinessError;
      this.appendVpnLog(`[ERROR] 启动 VPN 失败 (code=${error.code}): ${error.message}`);
    }
  }

  private async stopVpn(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'AdBlockVpnAbility'
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
      this.vpnRunning = false;
      this.appendVpnLog('[STOP] 已停止本地 VPN 过滤服务');
    } catch (err) {
      const error = err as BusinessError;
      this.appendVpnLog(`[ERROR] 停止 VPN 失败 (code=${error.code}): ${error.message}`);
    }
  }

  private async testSampleAdDnsResolution(): Promise<void> {
    const testDomains: string[] = [
      'tmead.y.qq.com',
      'ad.y.qq.com',
      'adsmind.ugdtimg.com',
      'mi.gdt.qq.com',
      'u.y.qq.com'
    ];

    this.appendVpnLog('--- 开始执行广告域名 vs 正常业务域名 DNS 拦截自检 ---');
    for (const domain of testDomains) {
      const matchedRule = AdDomainRules.matchRule(domain);
      try {
        const addresses = await connection.getAddressesByName(domain);
        const ipList = addresses.map((item: connection.NetAddress) => item.address).join(', ');
        if (ipList === '0.0.0.0' || ipList.startsWith('0.0.0.0')) {
          this.appendVpnLog(`✅ [成功黑洞拦截] ${domain} (规则:${matchedRule}) -> ${ipList}`);
        } else {
          this.appendVpnLog(
            `${matchedRule ? '⚠️ [未被拦截!请确认VPN已启动]' : '🟢 [正常业务放行]'} ${domain} -> ${ipList}`
          );
        }
      } catch (err) {
        const error = err as BusinessError;
        if (matchedRule) {
          this.appendVpnLog(`✅ [已阻断NXDOMAIN] ${domain} -> 解析被拒绝 (code=${error.code})`);
        } else {
          this.appendVpnLog(`❌ [解析失败] ${domain} -> code=${error.code}`);
        }
      }
    }
  }

  private getFilteredVpnLogs(): string[] {
    if (this.filterMode === 'ALL') {
      return this.vpnLogs;
    }
    if (this.filterMode === 'BLOCK') {
      return this.vpnLogs.filter((item: string) => item.includes('[BLOCK]') || item.includes('[MARK]') || item.includes('✅'));
    }
    if (this.filterMode === 'WATCH') {
      return this.vpnLogs.filter((item: string) => item.includes('[WATCH]') || item.includes('[MARK]'));
    }
    if (this.filterMode === 'ALLOW') {
      return this.vpnLogs.filter((item: string) => item.includes('[ALLOW]') || item.includes('[MARK]'));
    }
    return this.vpnLogs;
  }

  private extractDomainFromLogLine(line: string): string | null {
    const match = line.match(/(?:域名:|解析完成\]|普通放行:|拦截广告DNS:)\s*([a-zA-Z0-9._-]+\.[a-zA-Z]{2,})/);
    if (match && match[1]) {
      return match[1];
    }
    return null;
  }

  /**
   * 🎯 目标应用白名单与模式管理卡片
   */
  @Builder
  buildTargetAppsCard() {
    Column({ space: 8 }) {
      // 标题栏与折叠切换
      Row() {
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Text('🎯 跳过目标应用')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#182431')
            Text(this.targetConfig.mode === 'TARGETS_ONLY' ? '仅目标应用(防误触)' : '全部应用(全局)')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.targetConfig.mode === 'TARGETS_ONLY' ? '#007F54' : '#0052D9')
              .backgroundColor(this.targetConfig.mode === 'TARGETS_ONLY' ? '#E6F7F0' : '#EBF3FF')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
          }
          Text(`已启用 ${this.getEnabledTargetAppsCount()}/${this.targetConfig.apps.length} 款 · 未在清单应用 0 扫描 0 误触`)
            .fontSize(11)
            .fontColor('#666666')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.showTargetAppsPanel ? '收起 ▲' : '管理 ▼')
          .height(28)
          .fontSize(11)
          .backgroundColor(this.showTargetAppsPanel ? '#E5E8EB' : '#0052D9')
          .fontColor(this.showTargetAppsPanel ? '#182431' : '#FFFFFF')
          .onClick(() => {
            this.showTargetAppsPanel = !this.showTargetAppsPanel;
          })
      }
      .width('100%')

      if (this.showTargetAppsPanel) {
        // 模式切换行
        Row({ space: 6 }) {
          Button('🎯 仅目标应用 (推荐·防误触)')
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .fontWeight(this.targetConfig.mode === 'TARGETS_ONLY' ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.targetConfig.mode === 'TARGETS_ONLY' ? '#007F54' : '#F1F3F5')
            .fontColor(this.targetConfig.mode === 'TARGETS_ONLY' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.setSkipMode('TARGETS_ONLY');
            })

          Button('🌐 全部应用 (全局扫描)')
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .fontWeight(this.targetConfig.mode === 'ALL' ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.targetConfig.mode === 'ALL' ? '#0052D9' : '#F1F3F5')
            .fontColor(this.targetConfig.mode === 'ALL' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.setSkipMode('ALL');
            })
        }
        .width('100%')

        // 提示文本
        Text(this.targetConfig.mode === 'TARGETS_ONLY'
          ? '💡 仅目标模式：仅对下方列表中开启的应用执行广告检测与跳过；其他无广告应用彻底放行，杜绝一切误触与耗电。'
          : '⚠️ 全局模式：对打开的所有应用均执行开屏广告探针，容易在无广告应用首页引发误触，不建议日常开启。')
          .fontSize(10)
          .fontColor(this.targetConfig.mode === 'TARGETS_ONLY' ? '#007F54' : '#ED7B2F')
          .width('100%')

        // 手动添加应用表单
        Row({ space: 6 }) {
          TextInput({ placeholder: '应用名 (例: 夸克)', text: this.newAppName })
            .layoutWeight(1)
            .height(32)
            .fontSize(11)
            .onChange((val: string) => {
              this.newAppName = val;
            })

          TextInput({ placeholder: '包名 (例: com.quark.browser)', text: this.newAppBundle })
            .layoutWeight(1.4)
            .height(32)
            .fontSize(11)
            .onChange((val: string) => {
              this.newAppBundle = val;
            })

          Button('➕ 添加')
            .height(32)
            .fontSize(11)
            .backgroundColor('#7A3E9D')
            .onClick(() => {
              this.addCustomTargetApp();
            })
        }
        .width('100%')

        // 快捷操作行
        Row({ space: 8 }) {
          Text(`目标应用 (${this.targetConfig.apps.length})`)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4E5969')
            .layoutWeight(1)

          Text('全选')
            .fontSize(11)
            .fontColor('#0052D9')
            .onClick(() => {
              this.batchToggleAllTargetApps(true);
            })

          Text('全不选')
            .fontSize(11)
            .fontColor('#888888')
            .onClick(() => {
              this.batchToggleAllTargetApps(false);
            })

          Text('重置预置')
            .fontSize(11)
            .fontColor('#E34D59')
            .onClick(() => {
              this.resetTargetAppsToDefault();
            })
        }
        .width('100%')

        // 目标应用滚动列表 (高度固定在 150vp)
        List({ space: 4 }) {
          ForEach(this.targetConfig.apps, (item: TargetAppItem) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Row({ space: 4 }) {
                    Text(item.name)
                      .fontSize(12)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#182431')
                    if (item.isCustom) {
                      Text('自定义')
                        .fontSize(9)
                        .fontColor('#7A3E9D')
                        .backgroundColor('#F3E8FF')
                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                        .borderRadius(3)
                    }
                  }
                  Text(item.bundleName)
                    .fontSize(10)
                    .fontColor('#888888')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (item.probeRule) {
                    if (item.probeRule.strategy === 'PROBE') {
                      Text(`⏱️ 坐标探针: ${item.probeRule.delayMs}ms · (${item.probeRule.coordX},${item.probeRule.coordY}) · ${item.probeRule.repeatTimes || 4}次`)
                        .fontSize(9)
                        .fontColor('#0052D9')
                    } else if (item.probeRule.strategy === 'AUTO_PROBE') {
                      Text(`⚡ 自动+探针: ${item.probeRule.delayMs}ms · (${item.probeRule.coordX},${item.probeRule.coordY}) · ${item.probeRule.repeatTimes || 4}次`)
                        .fontSize(9)
                        .fontColor('#7A3E9D')
                    } else if (item.probeRule.strategy === 'DISABLED') {
                      Text('🚫 保持关闭')
                        .fontSize(9)
                        .fontColor('#888888')
                    } else {
                      Text('🎯 默认自动跳过')
                        .fontSize(9)
                        .fontColor('#00A870')
                    }
                  } else {
                    Text('🎯 默认自动跳过')
                      .fontSize(9)
                      .fontColor('#00A870')
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button(item.probeRule?.strategy === 'PROBE' ? '⏱️' : (item.probeRule?.strategy === 'AUTO_PROBE' ? '⚡' : '⚙️'))
                  .height(24)
                  .width(32)
                  .fontSize(11)
                  .backgroundColor('#EBF3FF')
                  .fontColor('#0052D9')
                  .margin({ right: 6 })
                  .onClick(() => {
                    this.openProbeRuleEditor(item);
                  })

                if (item.isCustom) {
                  Button('🗑️')
                    .height(24)
                    .width(28)
                    .fontSize(10)
                    .backgroundColor('#FDECEE')
                    .fontColor('#E34D59')
                    .margin({ right: 6 })
                    .onClick(() => {
                      this.removeTargetApp(item.bundleName);
                    })
                }

                Toggle({ type: ToggleType.Switch, isOn: item.enabled })
                  .selectedColor('#00A870')
                  .switchPointColor('#FFFFFF')
                  .onChange((isOn: boolean) => {
                    this.toggleTargetApp(item.bundleName, isOn);
                  })
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor('#FFFFFF')
              .borderRadius(6)
            }
          }, (item: TargetAppItem) => `${item.bundleName}_${item.enabled}_${item.probeRule?.strategy}_${item.probeRule?.delayMs}_${item.probeRule?.coordX}_${item.probeRule?.coordY}_${item.probeRule?.repeatTimes}`)
        }
        .width('100%')
        .height(150)
        .padding(4)
        .backgroundColor('#E5E8EB')
        .borderRadius(8)

        // ⏱️ 自绘/无障碍失明应用探针参数调节弹层 (支持滚动，防止顶出屏幕)
        if (this.editingProbeApp) {
          Scroll() {
            Column({ space: 8 }) {
              Row() {
                Text(`⚙️ 配置【${this.editingProbeApp.name}】跳过方式`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0052D9')
                  .layoutWeight(1)

                Text('✕ 关闭')
                  .fontSize(11)
                  .fontColor('#888888')
                  .onClick(() => {
                    this.editingProbeApp = null;
                  })
              }
              .width('100%')

              Text('提示: 默认自动可秒跳大多数App；腾讯视频等自绘应用推荐选「坐标探针」。')
                .fontSize(10)
                .fontColor('#666666')

              // 模式切换单选按钮组
              Text('选择跳过方式:')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182431')

              Row({ space: 4 }) {
                Button('🎯 默认自动')
                  .height(28)
                  .fontSize(10)
                  .backgroundColor(this.editStrategy === 'AUTO' ? '#00A870' : '#F1F3F5')
                  .fontColor(this.editStrategy === 'AUTO' ? '#FFFFFF' : '#182431')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.editStrategy = 'AUTO';
                  })

                Button('⏱️ 坐标探针')
                  .height(28)
                  .fontSize(10)
                  .backgroundColor(this.editStrategy === 'PROBE' ? '#0052D9' : '#F1F3F5')
                  .fontColor(this.editStrategy === 'PROBE' ? '#FFFFFF' : '#182431')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.editStrategy = 'PROBE';
                  })

                Button('⚡ 自动+兜底')
                  .height(28)
                  .fontSize(10)
                  .backgroundColor(this.editStrategy === 'AUTO_PROBE' ? '#7A3E9D' : '#F1F3F5')
                  .fontColor(this.editStrategy === 'AUTO_PROBE' ? '#FFFFFF' : '#182431')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.editStrategy = 'AUTO_PROBE';
                  })

                Button('🚫 关闭')
                  .height(28)
                  .fontSize(10)
                  .backgroundColor(this.editStrategy === 'DISABLED' ? '#E34D59' : '#F1F3F5')
                  .fontColor(this.editStrategy === 'DISABLED' ? '#FFFFFF' : '#182431')
                  .layoutWeight(0.8)
                  .onClick(() => {
                    this.editStrategy = 'DISABLED';
                  })
              }
              .width('100%')

              if (this.editStrategy !== 'DISABLED') {
                Row({ space: 6 }) {
                  Text('初始延迟(ms):')
                    .fontSize(11)
                    .fontColor('#182431')
                    .width(85)
                  TextInput({ text: this.editDelayMs })
                    .layoutWeight(1)
                    .height(30)
                    .fontSize(11)
                    .type(InputType.Number)
                    .onChange((val: string) => {
                      this.editDelayMs = val;
                    })

                  Text('重复检测次数:')
                    .fontSize(11)
                    .fontColor('#182431')
                    .width(80)
                  TextInput({ text: this.editRepeatTimes })
                    .width(50)
                    .height(30)
                    .fontSize(11)
                    .type(InputType.Number)
                    .onChange((val: string) => {
                      this.editRepeatTimes = val;
                    })
                }
                .width('100%')

                Row({ space: 6 }) {
                  Text('点击 X 坐标:')
                    .fontSize(11)
                    .fontColor('#182431')
                    .width(85)
                  TextInput({ text: this.editCoordX })
                    .layoutWeight(1)
                    .height(30)
                    .fontSize(11)
                    .type(InputType.Number)
                    .onChange((val: string) => {
                      this.editCoordX = val;
                    })

                  Text('Y 坐标:')
                    .fontSize(11)
                    .fontColor('#182431')
                    .width(45)
                  TextInput({ text: this.editCoordY })
                    .layoutWeight(1)
                    .height(30)
                    .fontSize(11)
                    .type(InputType.Number)
                    .onChange((val: string) => {
                      this.editCoordY = val;
                    })
                }
                .width('100%')
              }

              Row({ space: 8 }) {
                Button('推荐自绘(200ms/1135,185/4次)')
                  .height(28)
                  .fontSize(10)
                  .backgroundColor('#F1F3F5')
                  .fontColor('#0052D9')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.editStrategy = 'PROBE';
                    this.editDelayMs = '200';
                    this.editCoordX = '1135';
                    this.editCoordY = '185';
                    this.editRepeatTimes = '4';
                  })

                Button('💾 保存并应用')
                  .height(28)
                  .fontSize(11)
                  .backgroundColor('#0052D9')
                  .fontColor('#FFFFFF')
                  .padding({ left: 12, right: 12 })
                  .onClick(() => {
                    this.saveCurrentProbeRule();
                  })
              }
              .width('100%')
            }
            .width('100%')
          }
          .width('100%')
          .height(190)
          .scrollBar(BarState.Auto)
          .padding(10)
          .backgroundColor('#F0F4FF')
          .borderRadius(8)
          .border({ width: 1, color: '#B8D3FE' })
        }
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F8F9FA')
    .borderRadius(10)
    .border({ width: 1, color: '#E5E8EB' })
  }

  /**
   * 视图 1：⚡ 开屏广告自动点击跳过
   */
  @Builder
  buildAutoSkipPage() {
    Scroll() {
      Column({ space: 10 }) {
        // 状态统计卡片
        Row() {
          Column({ space: 4 }) {
            Text(this.daemonEnabled ? '已启用' : '已暂停')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.daemonEnabled ? '#00A870' : '#ED7B2F')
            Text(this.daemonRunning ? `守护运行中${this.daemonPid > 0 ? ' · PID ' + this.daemonPid : ''}` : '跳过服务状态')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)

          Column({ space: 4 }) {
            Text(`${this.skippedCount}`)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#7A3E9D')
            Text('累计跳过 (次)')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)

          Column({ space: 4 }) {
            Text('智能触控')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0052D9')
            Text('跳过控件识别')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#F1F3F5')
        .borderRadius(10)

        // 核心开关与一键重启卡片
        Row({ space: 8 }) {
          Column({ space: 3 }) {
            Text(this.daemonEnabled ? '⚡ 全场景广告自动跳过已开启 (含Resume/切回秒跳)' : '⏸️ 广告自动跳过已暂停')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#182431')
            Text(this.daemonEnabled ? '已增强支持冷热启动、后台Resume切回与锁屏亮屏广告秒跳。若失效可点「重启」' : '当前已暂停自动跳过，点击右侧「开启」即可恢复并重置引擎')
              .fontSize(11)
              .fontColor('#666666')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .onClick(() => {
            this.toggleLocalSkipDaemon();
          })

          Button('🔄 重启')
            .height(34)
            .padding({ left: 12, right: 12 })
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#0052D9')
            .onClick(() => {
              this.syncLocalSkipDaemon('/restart');
            })

          Button(this.daemonEnabled ? '暂停' : '开启')
            .height(34)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.daemonEnabled ? '#ED7B2F' : '#00A870')
            .onClick(() => {
              this.toggleLocalSkipDaemon();
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(this.daemonEnabled ? '#EBF9F3' : '#FFF6ED')
        .borderRadius(10)
        .border({
          width: 1,
          color: this.daemonEnabled ? '#B8EBD6' : '#FAD9B8'
        })

        // 🎯 目标应用过滤与管理卡片
        this.buildTargetAppsCard()

        // 日志操作栏
        Row({ space: 8 }) {
          Text('实时跳过记录')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4E5969')
            .layoutWeight(1)

          Button('🔄 刷新')
            .height(30)
            .fontSize(11)
            .backgroundColor('#0052D9')
            .onClick(() => {
              this.syncLocalSkipDaemon('/status');
              this.reloadSkipLogs();
            })

          Button('🗑️ 清空')
            .height(30)
            .fontSize(11)
            .backgroundColor('#888888')
            .onClick(() => {
              this.clearSkipLogs();
            })
        }
        .width('100%')

        // 自动跳过实时日志面板
        List({ space: 6, scroller: this.skipScroller }) {
          ForEach(this.skipLogs, (item: string, index: number) => {
            ListItem() {
              Text(item)
                .fontSize(11)
                .fontFamily('monospace')
                .width('100%')
                .padding(8)
                .backgroundColor(
                  item.includes('[SKIP]') ? '#F3E8FF' :
                  item.includes('[SKIP-SVC]') ? '#E6F7F0' : '#FFFFFF'
                )
                .borderRadius(6)
                .fontColor(
                  item.includes('[SKIP]') ? '#7A3E9D' :
                  item.includes('[SKIP-SVC]') ? '#007F54' : '#182431'
                )
            }
          }, (item: string, index: number) => `skip_${index}_${item}`)
        }
        .width('100%')
        .height(220)
        .padding(8)
        .backgroundColor('#F1F3F5')
        .borderRadius(10)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 视图 2：🛡️ VPN 广告域名过滤
   */
  @Builder
  buildVpnFilterPage() {
    Scroll() {
      Column({ space: 8 }) {
        // VPN 状态卡片
        Row() {
          Column({ space: 2 }) {
            Text(this.vpnRunning ? '运行中' : '未启动')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.vpnRunning ? '#00A870' : '#E34D59')
            Text('VPN 状态')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(`${this.blockedCount}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#00A870')
            Text('DNS拦截')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(`${this.watchCount}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#ED7B2F')
            Text('可疑监控')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(`${this.ruleCount}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0052D9')
            Text('黑名单规则')
              .fontSize(11)
              .fontColor('#666666')
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F1F3F5')
        .borderRadius(10)

        // 核心操作栏：启动/停止 VPN + 刷新/清空日志
        Row({ space: 8 }) {
          Button(this.vpnRunning ? '🔄 重启 VPN' : '🛡️ 启动本地 VPN')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .backgroundColor('#0052D9')
            .onClick(() => {
              this.startVpn();
            })

          Button('停止 VPN')
            .width(84)
            .height(38)
            .fontSize(13)
            .backgroundColor('#E34D59')
            .onClick(() => {
              this.stopVpn();
            })

          Button('刷新')
            .width(60)
            .height(38)
            .fontSize(12)
            .backgroundColor('#4E5969')
            .onClick(() => {
              this.reloadVpnLogs();
              this.sendVpnCommand('STATUS');
            })

          Button('清空')
            .width(60)
            .height(38)
            .fontSize(12)
            .backgroundColor('#888888')
            .onClick(() => {
              this.clearVpnLogs();
            })
        }
        .width('100%')

        // 添加自定义广告域名
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入或点击下方日志提取要拉黑的域名', text: this.customDomain })
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .onChange((val: string) => {
              this.customDomain = val;
            })

          Button('拉黑并热生效')
            .height(36)
            .fontSize(12)
            .backgroundColor('#ED7B2F')
            .onClick(() => {
              const target = this.customDomain.trim();
              if (target.length > 0) {
                const context = getContext(this) as common.UIAbilityContext;
                AdDomainRules.addRule(target, context.filesDir);
                this.ruleCount = AdDomainRules.getAllRules().length;
                this.sendVpnCommand('RELOAD_RULES');
                this.appendVpnLog(`[RULE] 已持久化拉黑域名并通知 VPN 进程热生效: ${target}`);
                this.customDomain = '';
              }
            })
        }
        .width('100%')

        // 特殊应用调试折叠入口
        Column({ space: 6 }) {
          Row() {
            Text('🔧 特殊应用调试')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#4E5969')
              .layoutWeight(1)

            Text(this.showSpecialDebug ? '收起 ▲' : '展开 ▼')
              .fontSize(11)
              .fontColor('#0052D9')
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor('#F7F8FA')
          .borderRadius(8)
          .onClick(() => {
            this.showSpecialDebug = !this.showSpecialDebug;
          })

          if (this.showSpecialDebug) {
            Row({ space: 8 }) {
              Button('🧪 广告域名 DNS 拦截自检')
                .layoutWeight(1)
                .height(34)
                .fontSize(12)
                .backgroundColor('#00A870')
                .onClick(() => {
                  this.testSampleAdDnsResolution();
                })

              Button('📌 插入应用抓包标记并保活')
                .layoutWeight(1)
                .height(34)
                .fontSize(12)
                .backgroundColor('#7A3E9D')
                .onClick(async () => {
                  await this.startVpn();
                  this.sendVpnCommand('MARK:>>> 准备切往目标应用抓包 <<<');
                  this.appendVpnLog('[MARK] ========== 已保活VPN并插入目标应用抓包标记 ==========');
                })
            }
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 2 })
          }
        }
        .width('100%')

        // 日志分类筛选栏
        Row({ space: 6 }) {
          Button(`全部(${this.vpnLogs.length})`)
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.filterMode === 'ALL' ? '#182431' : '#E5E8EB')
            .fontColor(this.filterMode === 'ALL' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.filterMode = 'ALL';
            })

          Button(`🎯拦截(${this.blockedCount})`)
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.filterMode === 'BLOCK' ? '#00A870' : '#E5E8EB')
            .fontColor(this.filterMode === 'BLOCK' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.filterMode = 'BLOCK';
            })

          Button(`🔍可疑监控(${this.watchCount})`)
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.filterMode === 'WATCH' ? '#ED7B2F' : '#E5E8EB')
            .fontColor(this.filterMode === 'WATCH' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.filterMode = 'WATCH';
            })

          Button(`🟢放行(${this.allowedCount})`)
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.filterMode === 'ALLOW' ? '#0052D9' : '#E5E8EB')
            .fontColor(this.filterMode === 'ALLOW' ? '#FFFFFF' : '#182431')
            .onClick(() => {
              this.filterMode = 'ALLOW';
            })
        }
        .width('100%')

        // VPN 实时日志面板
        List({ space: 6, scroller: this.vpnScroller }) {
          ForEach(this.getFilteredVpnLogs(), (item: string, index: number) => {
            ListItem() {
              Text(item)
                .fontSize(11)
                .fontFamily('monospace')
                .width('100%')
                .padding(6)
                .backgroundColor(
                  item.includes('[MARK]') ? '#F3E8FF' :
                  item.includes('[BLOCK]') || item.includes('✅') ? '#E6F7F0' :
                  item.includes('[WATCH]') ? '#FFF4E8' :
                  item.includes('[ERROR]') ? '#FDECEE' : '#FFFFFF'
                )
                .borderRadius(6)
                .fontColor(
                  item.includes('[ERROR]') || item.includes('❌') ? '#E34D59' :
                  item.includes('[MARK]') ? '#7A3E9D' :
                  item.includes('[BLOCK]') || item.includes('✅') ? '#007F54' :
                  item.includes('[WATCH]') ? '#C65911' : '#182431'
                )
                .onClick(() => {
                  const domain = this.extractDomainFromLogLine(item);
                  if (domain) {
                    this.customDomain = domain;
                  }
                })
            }
          }, (item: string, index: number) => `vpn_${index}_${item}`)
        }
        .width('100%')
        .height(240)
        .padding(8)
        .backgroundColor('#F1F3F5')
        .borderRadius(10)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Column({ space: 10 }) {
      // 顶部标题栏
      Column({ space: 2 }) {
        Text('AdSkipVpn · 广告净化工作台')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182431')
        Text('智能开屏跳过 · 本地 DNS 广告拦截')
          .fontSize(11)
          .fontColor('#666666')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ top: 8 })

      // 顶部分页切换导航栏
      Row({ space: 8 }) {
        Button(`⚡ 自动点击跳过 (${this.skippedCount})`)
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontWeight(this.activeTab === 0 ? FontWeight.Bold : FontWeight.Normal)
          .backgroundColor(this.activeTab === 0 ? '#7A3E9D' : '#E5E8EB')
          .fontColor(this.activeTab === 0 ? '#FFFFFF' : '#182431')
          .borderRadius(8)
          .onClick(() => {
            this.activeTab = 0;
          })

        Button(`🛡️ VPN 域名过滤 (${this.blockedCount})`)
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontWeight(this.activeTab === 1 ? FontWeight.Bold : FontWeight.Normal)
          .backgroundColor(this.activeTab === 1 ? '#0052D9' : '#E5E8EB')
          .fontColor(this.activeTab === 1 ? '#FFFFFF' : '#182431')
          .borderRadius(8)
          .onClick(() => {
            this.activeTab = 1;
          })
      }
      .width('100%')

      if (this.activeTab === 0) {
        this.buildAutoSkipPage()
      } else {
        this.buildVpnFilterPage()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
  }
}
