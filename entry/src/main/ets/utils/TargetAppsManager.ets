import { fileIo } from '@kit.CoreFileKit';

export type AppSkipStrategy = 'AUTO' | 'PROBE' | 'AUTO_PROBE' | 'DISABLED';

export interface CustomProbeRule {
  enabled: boolean;
  strategy?: AppSkipStrategy; // 跳过模式: AUTO(默认自动) | PROBE(专属坐标探针) | AUTO_PROBE(自动+探针兜底) | DISABLED(关闭)
  delayMs: number;            // 延迟时长 (毫秒)
  coordX: number;             // 点击 X 坐标
  coordY: number;             // 点击 Y 坐标
  repeatTimes?: number;       // 重复检测上限次数 (1-5次，默认4次)
}

export interface TargetAppItem {
  name: string;
  bundleName: string;
  enabled: boolean;
  isCustom?: boolean;
  probeRule?: CustomProbeRule;
}

export type SkipMode = 'TARGETS_ONLY' | 'ALL';

export interface TargetAppsConfig {
  mode: SkipMode;
  apps: TargetAppItem[];
}

export const DEFAULT_TARGET_APPS: TargetAppItem[] = [
  {
    name: '腾讯视频',
    bundleName: 'com.tencent.videohm',
    enabled: true,
    probeRule: {
      enabled: true,
      strategy: 'PROBE',
      delayMs: 200,
      coordX: 1135,
      coordY: 185,
      repeatTimes: 4
    }
  },
  {
    name: 'QQ音乐',
    bundleName: 'com.tencent.hm.qqmusic',
    enabled: true,
    probeRule: {
      enabled: true,
      strategy: 'AUTO',
      delayMs: 0,
      coordX: 1135,
      coordY: 185,
      repeatTimes: 4
    }
  },
  {
    name: '喜马拉雅',
    bundleName: 'com.ximalaya.ting.xmharmony',
    enabled: true,
    probeRule: {
      enabled: true,
      strategy: 'AUTO',
      delayMs: 0,
      coordX: 1135,
      coordY: 185,
      repeatTimes: 4
    }
  },
  {
    name: '山姆会员店',
    bundleName: 'cn.samsclub.hm.app',
    enabled: true,
    probeRule: {
      enabled: false,
      strategy: 'DISABLED',
      delayMs: 0,
      coordX: 0,
      coordY: 0,
      repeatTimes: 0
    }
  },
  { name: '爱奇艺', bundleName: 'com.qiyi.video.hmy', enabled: true },
  { name: '优酷视频', bundleName: 'com.youku.next', enabled: true },
  { name: '哔哩哔哩', bundleName: 'tv.danmaku.bili', enabled: true },
  { name: '微博', bundleName: 'com.sina.weibo.stage', enabled: true },
  { name: '知乎', bundleName: 'com.zhihu.hmos', enabled: true },
  { name: '抖音', bundleName: 'com.ss.hm.ugc.aweme', enabled: true },
  { name: '快手', bundleName: 'com.kuaishou.nebula', enabled: true },
  { name: '淘宝', bundleName: 'com.taobao.taobao4hmos', enabled: true },
  { name: '京东', bundleName: 'com.jd.harmony', enabled: true },
  { name: '网易云音乐', bundleName: 'com.netease.cloudmusic', enabled: true },
  { name: '小红书', bundleName: 'com.xingin.xhs', enabled: true },
  { name: '百度', bundleName: 'com.baidu.searchbox', enabled: true },
  { name: '高德地图', bundleName: 'com.autonavi.minimap', enabled: true },
  { name: '美团', bundleName: 'com.sankuai.meituan', enabled: true }
];

const TARGETS_JSON_FILE = '/adskip_targets.json';
const TARGETS_TXT_FILE = '/adskip_targets.txt';
const MODE_TXT_FILE = '/adskip_mode.txt';
const PROBE_CONFIG_TXT_FILE = '/adskip_probe_config.txt';

export class TargetAppsManager {
  /**
   * 加载目标跳过应用配置
   */
  public static loadConfig(filesDir: string): TargetAppsConfig {
    const jsonPath = filesDir + TARGETS_JSON_FILE;
    try {
      if (fileIo.accessSync(jsonPath)) {
        const text = fileIo.readTextSync(jsonPath).trim();
        if (text.length > 0) {
          const config = JSON.parse(text) as TargetAppsConfig;
          if (config && Array.isArray(config.apps)) {
            if (!config.mode) {
              config.mode = 'TARGETS_ONLY';
            }
            // 自动同步预置默认的 probeRule（如果本地持久化没有则合并）
            let needsResave = false;
            for (const defApp of DEFAULT_TARGET_APPS) {
              if (defApp.probeRule) {
                const cur = config.apps.find((a: TargetAppItem) => a.bundleName === defApp.bundleName);
                if (cur && !cur.probeRule) {
                  cur.probeRule = defApp.probeRule;
                  needsResave = true;
                }
              }
            }
            // 兼容已有规则缺失 strategy 与 repeatTimes 的升级
            for (const app of config.apps) {
              if (app.probeRule) {
                if (!app.probeRule.strategy) {
                  app.probeRule.strategy = app.probeRule.enabled ? 'PROBE' : 'AUTO';
                  needsResave = true;
                }
                if (!app.probeRule.repeatTimes) {
                  app.probeRule.repeatTimes = 4;
                  needsResave = true;
                }
              }
            }
            if (needsResave) {
              TargetAppsManager.saveConfig(filesDir, config);
            }
            return config;
          }
        }
      }
    } catch (_) {
    }

    const defaultConfig: TargetAppsConfig = {
      mode: 'TARGETS_ONLY',
      apps: JSON.parse(JSON.stringify(DEFAULT_TARGET_APPS))
    };
    TargetAppsManager.saveConfig(filesDir, defaultConfig);
    return defaultConfig;
  }

  /**
   * 更新某个应用的自绘探针规则 (延迟/坐标)
   */
  public static updateProbeRule(filesDir: string, bundleName: string, probeRule: CustomProbeRule): TargetAppsConfig {
    const config = TargetAppsManager.loadConfig(filesDir);
    const target = config.apps.find((item: TargetAppItem) => item.bundleName === bundleName);
    if (target) {
      target.probeRule = probeRule;
      TargetAppsManager.saveConfig(filesDir, config);
    }
    return config;
  }

  /**
   * 持久化目标跳过应用配置，并生成供守护脚本秒级读取的 txt 清单
   */
  public static saveConfig(filesDir: string, config: TargetAppsConfig): void {
    try {
      const jsonPath = filesDir + TARGETS_JSON_FILE;
      const jsonContent = JSON.stringify(config, null, 2);
      const jFile = fileIo.openSync(jsonPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(jFile.fd, jsonContent);
      fileIo.closeSync(jFile);

      // 生成 txt 格式的启用白名单，守护脚本可直接使用 grep -F 秒级判定
      const enabledBundles = config.apps
        .filter((item: TargetAppItem) => item.enabled)
        .map((item: TargetAppItem) => item.bundleName.trim())
        .filter((b: string) => b.length > 0);
      const txtContent = enabledBundles.join('\n') + '\n';
      const txtPath = filesDir + TARGETS_TXT_FILE;
      const tFile = fileIo.openSync(txtPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(tFile.fd, txtContent);
      fileIo.closeSync(tFile);

      // 生成模式说明文件 (TARGETS_ONLY / ALL)
      const modePath = filesDir + MODE_TXT_FILE;
      const mFile = fileIo.openSync(modePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(mFile.fd, config.mode + '\n');
      fileIo.closeSync(mFile);

      // 生成自绘/自定义应用跳过规则配置文本 (adskip_probe_config.txt)，供后台守护脚本实时读取
      const probeLines: string[] = [
        '# ============================================================================',
        '# 应用独立跳过策略与参数配置表 (模式: AUTO默认自动 / PROBE专属探针 / AUTO_PROBE自动+探针兜底 / DISABLED关闭)',
        '# 每行格式: 应用包名=跳过模式,延迟时长(毫秒),点击X坐标,点击Y坐标,尝试次数(1-5)',
        '# ============================================================================'
      ];
      for (const app of config.apps) {
        if (app.probeRule) {
          let strat: AppSkipStrategy = app.probeRule.strategy || (app.probeRule.enabled ? 'PROBE' : 'AUTO');
          if (!app.enabled) {
            strat = 'DISABLED';
          }
          const repeat = Math.max(1, Math.min(5, app.probeRule.repeatTimes || 4));
          probeLines.push(`${app.bundleName}=${strat},${app.probeRule.delayMs},${app.probeRule.coordX},${app.probeRule.coordY},${repeat}`);
        }
      }
      const probeContent = probeLines.join('\n') + '\n';
      const probePath = filesDir + PROBE_CONFIG_TXT_FILE;
      const pFile = fileIo.openSync(probePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(pFile.fd, probeContent);
      fileIo.closeSync(pFile);
    } catch (_) {
    }
  }

  /**
   * 切换某个应用的启用状态
   */
  public static toggleApp(filesDir: string, bundleName: string, enabled: boolean): TargetAppsConfig {
    const config = TargetAppsManager.loadConfig(filesDir);
    const target = config.apps.find((item: TargetAppItem) => item.bundleName === bundleName);
    if (target) {
      target.enabled = enabled;
      TargetAppsManager.saveConfig(filesDir, config);
    }
    return config;
  }

  /**
   * 添加自定义应用
   */
  public static addApp(filesDir: string, name: string, bundleName: string): TargetAppsConfig {
    const cleanBundle = bundleName.trim();
    const cleanName = name.trim() || cleanBundle;
    const config = TargetAppsManager.loadConfig(filesDir);

    const existingIndex = config.apps.findIndex((item: TargetAppItem) => item.bundleName === cleanBundle);
    if (existingIndex >= 0) {
      config.apps[existingIndex].enabled = true;
      if (name.trim().length > 0) {
        config.apps[existingIndex].name = cleanName;
      }
    } else {
      config.apps.unshift({
        name: cleanName,
        bundleName: cleanBundle,
        enabled: true,
        isCustom: true
      });
    }

    TargetAppsManager.saveConfig(filesDir, config);
    return config;
  }

  /**
   * 删除自定义应用
   */
  public static removeApp(filesDir: string, bundleName: string): TargetAppsConfig {
    const config = TargetAppsManager.loadConfig(filesDir);
    config.apps = config.apps.filter((item: TargetAppItem) => item.bundleName !== bundleName);
    TargetAppsManager.saveConfig(filesDir, config);
    return config;
  }

  /**
   * 切换跳过范围模式 (TARGETS_ONLY / ALL)
   */
  public static setMode(filesDir: string, mode: SkipMode): TargetAppsConfig {
    const config = TargetAppsManager.loadConfig(filesDir);
    config.mode = mode;
    TargetAppsManager.saveConfig(filesDir, config);
    return config;
  }

  /**
   * 恢复为默认应用清单
   */
  public static resetToDefault(filesDir: string): TargetAppsConfig {
    const config: TargetAppsConfig = {
      mode: 'TARGETS_ONLY',
      apps: JSON.parse(JSON.stringify(DEFAULT_TARGET_APPS))
    };
    TargetAppsManager.saveConfig(filesDir, config);
    return config;
  }
}
