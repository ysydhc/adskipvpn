import {
  AccessibilityExtensionAbility,
  AccessibilityEvent,
  AccessibilityElement,
  GesturePath,
  GesturePoint,
  Rect
} from '@kit.AccessibilityKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VPN_LOG_EVENT, VPN_TRACE_LOG_FILE } from '../vpn/VpnAdBlockEngine';

const LOG_DOMAIN = 0xFF01;
const LOG_TAG = 'AdSkipAccessibility';

/**
 * 忽略扫描的系统与自身包名（桌面、系统UI、设置、本应用）
 */
const IGNORED_BUNDLES: string[] = [
  'com.ysydhc.adskipvpn',
  'com.huawei.hmos.sceneboard',
  'com.ohos.systemui',
  'com.huawei.hmos.settings',
  'com.huawei.hmsapp.screenreader'
];

/**
 * 排除歌词、正常功能按钮等包含“跳过”但并非开屏广告的文案
 */
const EXCLUDE_PHRASES: string[] = [
  '跳过片头',
  '跳过片尾',
  '跳过前奏',
  '跳过空白',
  '自动跳过',
  '不跳过',
  '跳过此',
  '已跳过',
  '为您跳过',
  '跳过广告特权',
  '免广告',
  '去广告'
];

/**
 * 严格匹配开屏“跳过”按钮文案：
 * 例如 "跳过"、"跳过 5"、"跳过4s"、"5s 跳过"、"跳过广告"、"关闭广告"
 */
const STRICT_SKIP_REGEX: RegExp =
  /^([0-9]{1,2}\s*[sS秒]?\s*[|｜·]?\s*)?(跳过(广告|开屏)?|关闭广告)(\s*[|｜·]?\s*[0-9]{1,2}\s*[sS秒]?)?$/;

/**
 * 原生鸿蒙无障碍开屏广告自动跳过扩展服务 (事件驱动，平时 0% CPU 休眠)
 */
export default class AdSkipAccessibilityAbility extends AccessibilityExtensionAbility {
  private lastForegroundBundle: string = '';
  private bundleEnterTimestamp: number = 0;
  private lastClickTimestamp: number = 0;
  private isScanning: boolean = false;
  private activeTimers: number[] = [];

  /**
   * 当用户在「设置 -> 辅助功能 -> 已安装的服务」中开启本服务时回调
   */
  onConnect(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'AdSkipAccessibilityAbility connected');
    this.emitLog('[SKIP-SVC] 🟢 原生无障碍「开屏自动跳过服务」已开启并就绪（纯事件驱动，待机0耗电）');
  }

  /**
   * 当无障碍服务被关闭或断开时回调
   */
  onDisconnect(): void {
    this.clearScheduledScans();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'AdSkipAccessibilityAbility disconnected');
    this.emitLog('[SKIP-SVC] 🔴 原生无障碍「开屏自动跳过服务」已停止');
  }

  /**
   * 收到系统无障碍事件时触发（仅在应用切换/开屏前 5 秒内扫描，平时直接返回不耗电）
   */
  onAccessibilityEvent(event: AccessibilityEvent): void {
    const now = Date.now();
    // 刚点击过跳过按钮后的 1.4 秒冷却期内不重复触发，防止误触首页
    if (now - this.lastClickTimestamp < 1400) {
      return;
    }

    const eventTypeStr = String(event.eventType ?? '');
    const isWindowOrPageEvent =
      eventTypeStr === 'add' ||
      eventTypeStr === 'active' ||
      eventTypeStr === 'focus' ||
      eventTypeStr === 'pageStateUpdate' ||
      eventTypeStr === 'pageContentUpdate';

    if (!isWindowOrPageEvent) {
      return;
    }

    this.handleWindowOrPageEvent(eventTypeStr);
  }

  private async handleWindowOrPageEvent(eventTypeStr: string): Promise<void> {
    if (this.isScanning) {
      return;
    }
    this.isScanning = true;
    try {
      const root: AccessibilityElement = await this.context.getWindowRootElement();
      if (!root) {
        return;
      }

      let bundleName = '';
      try {
        bundleName = (await root.attributeValue('bundleName')) ?? '';
      } catch (_) {
        bundleName = '';
      }

      // 如果切回桌面，记录状态并取消延时任务，便于下次从桌面打开同一 App 时重新计入开屏期
      if (bundleName === 'com.huawei.hmos.sceneboard') {
        if (this.lastForegroundBundle !== bundleName) {
          this.lastForegroundBundle = bundleName;
          this.clearScheduledScans();
        }
        return;
      }

      if (bundleName.length > 0 && IGNORED_BUNDLES.includes(bundleName)) {
        return;
      }

      const now = Date.now();
      if (bundleName.length > 0 && bundleName !== this.lastForegroundBundle) {
        // 检测到新应用进入前台！开启 5 秒开屏检测窗口，并安排几次轻量级延时复查（应对开屏广告异步加载）
        this.lastForegroundBundle = bundleName;
        this.bundleEnterTimestamp = now;
        this.scheduleFollowUpScans(bundleName);
      } else if (eventTypeStr === 'add' || eventTypeStr === 'active') {
        // 同一应用内新弹出全屏窗口或从后台热启动恢复，刷新检测窗口
        if (now - this.bundleEnterTimestamp > 5000) {
          this.bundleEnterTimestamp = now;
          this.scheduleFollowUpScans(bundleName);
        }
      }

      // 核心省电策略：仅在进入应用/窗口激活后的前 5 秒内检索“跳过”按钮，超时立即休眠
      if (now - this.bundleEnterTimestamp > 5000) {
        return;
      }

      await this.scanAndClickSkipOnRoot(root, bundleName);
    } catch (_) {
      // 忽略窗口切换瞬间的失效节点异常
    } finally {
      this.isScanning = false;
    }
  }

  /**
   * 针对部分 App（如 QQ 音乐、喜马拉雅）开屏广告在窗口创建后 300ms~2200ms 才渲染出来的情况，
   * 在进入新应用时仅安排 4 次定时快照检查，点中即停。
   */
  private scheduleFollowUpScans(targetBundle: string): void {
    this.clearScheduledScans();
    const delays: number[] = [350, 850, 1500, 2400];
    for (const delay of delays) {
      const timerId = setTimeout(async () => {
        if (Date.now() - this.lastClickTimestamp < 1400) {
          return;
        }
        if (this.lastForegroundBundle !== targetBundle) {
          return;
        }
        if (this.isScanning) {
          return;
        }
        this.isScanning = true;
        try {
          const root = await this.context.getWindowRootElement();
          if (root) {
            await this.scanAndClickSkipOnRoot(root, targetBundle);
          }
        } catch (_) {
        } finally {
          this.isScanning = false;
        }
      }, delay);
      this.activeTimers.push(timerId);
    }
  }

  private clearScheduledScans(): void {
    for (const timerId of this.activeTimers) {
      clearTimeout(timerId);
    }
    this.activeTimers = [];
  }

  /**
   * 在当前活动窗口根节点中查找并点击开屏“跳过”按钮
   */
  private async scanAndClickSkipOnRoot(root: AccessibilityElement, bundleName: string): Promise<boolean> {
    // 1. 优先使用系统 C++ 层原生快速检索 findElement('content', '跳过')
    let candidates: AccessibilityElement[] = [];
    try {
      const foundSkip = await root.findElement('content', '跳过');
      if (foundSkip && foundSkip.length > 0) {
        candidates = candidates.concat(foundSkip);
      }
    } catch (_) {
    }

    try {
      if (candidates.length === 0) {
        const foundCloseAd = await root.findElement('content', '关闭广告');
        if (foundCloseAd && foundCloseAd.length > 0) {
          candidates = candidates.concat(foundCloseAd);
        }
      }
    } catch (_) {
    }

    // 2. 如果系统级精确查找到候选节点，逐一校验位置与文案规则
    for (const item of candidates) {
      const clicked = await this.verifyAndTriggerSkip(item, bundleName);
      if (clicked) {
        return true;
      }
    }

    // 3. 兜底轻量级广度优先遍历（最多检查前 90 个节点，防止某些自定义组件未索引 content）
    return await this.bfsSearchSkipElement(root, bundleName, 90);
  }

  private async bfsSearchSkipElement(
    root: AccessibilityElement,
    bundleName: string,
    maxNodes: number
  ): Promise<boolean> {
    const queue: AccessibilityElement[] = [root];
    let visited = 0;

    while (queue.length > 0 && visited < maxNodes) {
      const current = queue.shift();
      if (!current) {
        continue;
      }
      visited += 1;

      const clicked = await this.verifyAndTriggerSkip(current, bundleName);
      if (clicked) {
        return true;
      }

      try {
        const children = await current.attributeValue('children');
        if (children && children.length > 0) {
          for (const child of children) {
            queue.push(child);
          }
        }
      } catch (_) {
      }
    }
    return false;
  }

  /**
   * 校验单个无障碍节点是否为真实的开屏“跳过”按钮，若是则立即触发手势点击 + 节点点击
   */
  private async verifyAndTriggerSkip(elem: AccessibilityElement, bundleName: string): Promise<boolean> {
    try {
      let text = '';
      let accText = '';
      let desc = '';
      try {
        text = (await elem.attributeValue('text')) ?? '';
      } catch (_) {
      }
      try {
        accText = (await elem.attributeValue('accessibilityText')) ?? '';
      } catch (_) {
      }
      try {
        desc = (await elem.attributeValue('description')) ?? '';
      } catch (_) {
      }

      const label = this.pickSkipLabel(text, accText, desc);
      if (!label) {
        return false;
      }

      const rect: Rect | undefined = await elem.attributeValue('screenRect');
      if (!rect) {
        return false;
      }

      // 校验按钮尺寸合理性（排除整屏容器）
      if (rect.width < 18 || rect.width > 520 || rect.height < 18 || rect.height > 240) {
        return false;
      }

      const cx = Math.round(rect.left + rect.width / 2);
      const cy = Math.round(rect.top + rect.height / 2);

      // 开屏跳过按钮位于屏幕上方区域 (top < 520) 或底部角落 (top > 1750)
      const inValidCorner = (cy > 60 && cy < 520) || cy > 1750;
      if (!inValidCorner) {
        return false;
      }

      // 触发点击！优先通过 injectGestureSync 注入真实屏幕坐标点击，同时辅以 performAction('click')
      let clickSuccess = false;
      try {
        const point = new GesturePoint(cx, cy);
        const gesturePath = new GesturePath(45);
        gesturePath.points = [point];
        this.context.injectGestureSync(gesturePath);
        clickSuccess = true;
      } catch (gestureErr) {
        const gErr = gestureErr as BusinessError;
        hilog.warn(LOG_DOMAIN, LOG_TAG, `injectGestureSync failed: %{public}s`, gErr?.message ?? '');
      }

      try {
        await elem.performAction('click');
        clickSuccess = true;
      } catch (_) {
      }

      if (clickSuccess) {
        this.lastClickTimestamp = Date.now();
        this.clearScheduledScans();
        this.emitLog(
          `[SKIP] ⚡ 已自动跳过开屏广告! 应用=${bundleName || '当前前台'} 文案="${label}" 坐标=(${cx}, ${cy})`
        );
        return true;
      }
    } catch (_) {
    }
    return false;
  }

  /**
   * 判断节点文本是否匹配开屏“跳过”规则
   */
  private pickSkipLabel(text: string, accText: string, desc: string): string | null {
    const fields: string[] = [text.trim(), accText.trim(), desc.trim()];
    for (const raw of fields) {
      if (!raw || raw.length > 14) {
        continue;
      }
      if (!raw.includes('跳过') && !raw.includes('关闭广告')) {
        continue;
      }
      let excluded = false;
      for (const bad of EXCLUDE_PHRASES) {
        if (raw.includes(bad)) {
          excluded = true;
          break;
        }
      }
      if (excluded) {
        continue;
      }
      if (STRICT_SKIP_REGEX.test(raw)) {
        return raw;
      }
      if ((raw.startsWith('跳过') || raw.endsWith('跳过')) && raw.length <= 9) {
        return raw;
      }
    }
    return null;
  }

  /**
   * 写入共享持久化日志并向主界面广播
   */
  private emitLog(message: string): void {
    const now = new Date();
    const timeStr =
      `${now.getHours().toString().padStart(2, '0')}:` +
      `${now.getMinutes().toString().padStart(2, '0')}:` +
      `${now.getSeconds().toString().padStart(2, '0')}.` +
      `${now.getMilliseconds().toString().padStart(3, '0')}`;
    const fullLine = `${timeStr} ${message}`;

    try {
      const path = this.context.filesDir + VPN_TRACE_LOG_FILE;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${fullLine}\n`);
      fileIo.closeSync(file);
    } catch (_) {
    }

    try {
      commonEventManager.publish(
        VPN_LOG_EVENT,
        {
          data: fullLine
        },
        () => {}
      );
    } catch (_) {
    }
  }
}
