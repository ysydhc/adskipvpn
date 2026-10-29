import { vpnExtension, connection } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { AdDomainRules } from '../vpn/AdDomainRules';
import { VPN_LOG_EVENT, VPN_CMD_EVENT, VPN_TRACE_LOG_FILE } from '../vpn/VpnAdBlockEngine';
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
      if (fileIo.accessSync(scriptPath)) {
        const stat = fileIo.statSync(scriptPath);
        if (stat.size > rawScript.byteLength) {
          return;
        }
      }
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
   * 视图 1：⚡ 开屏广告自动点击跳过
   */
  @Builder
  buildAutoSkipPage() {
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
          Text(this.daemonEnabled ? '⚡ 开屏广告自动跳过已开启' : '⏸️ 开屏广告自动跳过已暂停')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182431')
          Text(this.daemonEnabled ? '若遇到跳过失效，可点击「重启」或重新开启即时恢复' : '当前已暂停自动跳过，点击右侧「开启」即可恢复并重置引擎')
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
      .layoutWeight(1)
      .padding(8)
      .backgroundColor('#F1F3F5')
      .borderRadius(10)
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 视图 2：🛡️ VPN 广告域名过滤
   */
  @Builder
  buildVpnFilterPage() {
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
      .layoutWeight(1)
      .padding(8)
      .backgroundColor('#F1F3F5')
      .borderRadius(10)
    }
    .width('100%')
    .layoutWeight(1)
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
