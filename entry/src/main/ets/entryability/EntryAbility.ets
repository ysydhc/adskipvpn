import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private bgTerminateTimer: number = -1;

  private clearBgTerminateTimer(): void {
    if (this.bgTerminateTimer !== -1) {
      clearTimeout(this.bgTerminateTimer);
      this.bgTerminateTimer = -1;
    }
  }

  private dumpTraceLogToHilog(): void {
    try {
      const path = `${this.context.filesDir}/vpn_dns_trace.log`;
      if (!fileIo.accessSync(path)) {
        hilog.info(DOMAIN, 'testTag', 'TRACE_EMPTY: no vpn_dns_trace.log');
        return;
      }
      const content = fileIo.readTextSync(path);
      const lines = content.split('\n').filter((l: string) => l.trim().length > 0);
      hilog.info(DOMAIN, 'testTag', 'TRACE_TOTAL: %{public}d lines', lines.length);
      const recent = lines.slice(Math.max(0, lines.length - 150));
      for (let i = 0; i < recent.length; i++) {
        hilog.info(DOMAIN, 'testTag', 'TRACE[%{public}d]: %{public}s', i, recent[i]);
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'TRACE_ERR: %{public}s', JSON.stringify(e));
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.dumpTraceLogToHilog();
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.dumpTraceLogToHilog();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.clearBgTerminateTimer();
  }

  onBackground(): void {
    // Ability has back to background: 退至后台后自动结束 UI 实例并从系统多任务后台卡片中移除
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    this.clearBgTerminateTimer();
    this.bgTerminateTimer = setTimeout(() => {
      this.bgTerminateTimer = -1;
      try {
        this.context.terminateSelf();
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'terminateSelf error: %{public}s', JSON.stringify(e));
      }
    }, 600);
  }
}