# 净享 / SafeShare

SafeShare 是一个 HarmonyOS NEXT 原生的“分享前隐私防火墙”。它在本机检查照片的隐私元数据与设备可用的视觉风险，按用户选择遮盖敏感区域，生成安全临时副本，并调用系统分享面板继续分享。

## 当前完成

- 从系统分享面板接收并处理单张或最多 50 张图片
- 通过系统图片选择器选择图片，不申请全量相册权限
- 扫描 GPS、时间、设备、所有者、序列号、软件、作者、版权、描述和备注等隐私元数据
- 已接入设备端 Core Vision / Scan Kit 能力探测与失败降级；相关人脸、二维码能力仍受发布前真机矩阵门禁约束
- 风险只来自实际读取到的元数据与真实检测结果，不进行 OCR 文字分类
- 视觉风险可逐项选择，支持智能推荐、强模糊、马赛克和纯色遮盖
- 检测框叠加在完整 `Contain` 预览上，用户可逐项决定是否遮盖
- 元数据支持推荐清理、一键全清除和自定义；默认策略持久化，本次处理可单独调整，并可替换拍摄时间、相机厂商/型号、作者、版权和描述
- 不支持动态照片（Moving Photo）：识别后直接拒绝，避免半截处理或静默降级成静态图
- 支持原图/安全副本预览；确认后才打开系统分享面板
- 解码像素并按设备编码能力优先保持 JPEG、PNG、HEIF 或 WebP 格式，不修改原文件
- 对设备实际返回且由用户选择的视觉区域执行输出复检；复检失败则阻止分享并删除不完整输出
- 使用 Share Kit 展示系统分享面板
- 分享完成或面板关闭后短暂延迟清理临时副本；下次启动也会清理遗留副本
- 批量逐张预览、统计与打码选择；取消操作后忽略过期结果并清理已生成副本
- 视觉管线只解码一张最长边 1600 的 RGBA 检测图；检测框按 X/Y 比例映射回全分辨率，导出仅按区域读写像素
- 支持文字水印及图片水印；图片素材只复制到缓存沙箱，支持单枚/平铺、位置、缩放、透明度、旋转、边距和实时预览
- 可扩展 `PrivacyProcessor` 架构，图片处理器与 UI/分享逻辑解耦
- 原生浅色/深色主题与系统栏安全区适配；沉浸式全屏窗口 + 透明系统栏
- 全原生 UI：`HdsNavigation`/`HdsNavDestination` 标题栏（沉浸光感 + 滚动渐变模糊）、`HdsActionBar` 底部操作栏、原生 `bindMenu` 处理方式菜单、原生 `bindSheet` 毛玻璃弹层
- 首页使用右上角原生设置入口；结果页支持大图展开，元数据折叠展示，普通新闻人名/地点/日期不进入默认打码列表
- AppGallery 发布门禁、权限和 HarmonyOS 6.1 沉浸光感升级策略文档

## 构建

项目已使用 HarmonyOS 6.1.1 SDK（API 24）验证编译：

```bash
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install --all
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
  --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
```

构建产物位于 `entry/build/default/outputs/default/`。没有签名配置时产出 unsigned HAP；真机运行需在 DevEco Studio 中配置自动签名。

## 发布前仍需完成

API 24 编译已闭环，但当前测试目录尚无有效自动化用例。正式上架前仍必须完成真机能力矩阵、真实检测框打码验收、HEIF/HDR/透明 PNG 格式回归、发布签名、无障碍与商店材料。未通过真机门禁的端侧视觉能力不会写成商店“已支持”卖点，详见 `docs/RELEASE_CHECKLIST.md`。
