---
name: responsive-check
description: 自动检查多分辨率下页面表现。依次在常见设备分辨率下截图，检查布局是否正常、是否有溢出或错位问题。输出 HTML 报告并自动打开。
argument-hint: <页面地址>
allowed-tools: [Bash, Read, Glob, Write, mcp__playwright__browser_navigate, mcp__playwright__browser_take_screenshot, mcp__playwright__browser_snapshot, mcp__playwright__browser_resize, mcp__playwright__browser_evaluate, mcp__playwright__browser_press_key, mcp__playwright__browser_click, mcp__playwright__browser_handle_dialog]
---

# Responsive Check - 多分辨率检查

这个 skill 用于自动在多种常见设备分辨率下对页面截图，检查响应式布局是否正常，并生成 HTML 可视化报告。

## 参数规则

- 页面地址参数可选
- 若用户提供了地址，使用该地址
- 若未提供地址，使用当前浏览器已打开的页面
- 若当前没有已打开页面且未提供地址，提示用户提供

## 触发示例

- `/responsive-check http://localhost:8004/`
- `/responsive-check`
- `检查一下这个页面在手机上的表现`
- `帮我看看不同分辨率下的布局`

## 检查的分辨率列表

按以下顺序依次检查：

| 设备名称 | 宽度 x 高度 |
|---------|------------|
| iPhone SE | 375 x 667 |
| iPhone 14 | 390 x 844 |
| iPad Mini | 768 x 1024 |
| iPad Pro | 1024 x 1366 |
| 笔记本 | 1366 x 768 |
| 桌面 | 1920 x 1080 |

## 执行步骤

0. 清理已有的 Playwright 浏览器实例
   - 在开始任何操作之前，先尝试调用 `mcp__playwright__browser_navigate` 导航到目标页面
   - 如果报错 `Browser is already in use`，说明有残留的 Playwright 实例：
     a. 使用 Bash 关闭残留的 Playwright Chrome 进程：
        ```bash
        pkill -f "mcp-chrome" 2>/dev/null; sleep 1
        # macOS
        rm -f ~/Library/Caches/ms-playwright/mcp-chrome-*/SingletonLock 2>/dev/null
        # Linux
        rm -f ~/.cache/ms-playwright/mcp-chrome-*/SingletonLock 2>/dev/null
        ```
     b. 等待 1-2 秒后重新尝试导航
   - 如果没有报错则跳过此步骤，直接继续

1. 确定目标页面
   - 使用用户提供的地址，或当前浏览器已打开的页面
   - 导航到目标页面
   - 页面加载后，自动处理可能出现的干扰元素：
     a. **广告弹窗/浮窗**：检测页面上的弹窗广告、浮层广告，使用 `browser_snapshot` 找到关闭按钮（如 X、关闭、close 等）并点击关闭
     b. **年龄验证/限制警告**：如果页面弹出年龄确认对话框（如"请确认您已满18岁"），自动选择"18岁以上"/"已满18岁"/"进入"等确认按钮
     c. **Cookie 同意弹窗**：如有 Cookie 同意提示，自动点击"同意"/"接受"
     d. **循环关闭多个弹窗**：部分页面会连续弹出多个广告弹窗（关闭一个后立即弹出下一个）。每次关闭一个弹窗后，重新执行 `browser_snapshot` 检查是否还有新的弹窗/浮层，如有则继续关闭，循环直到页面上没有遮挡性弹窗为止
     e. 所有弹窗处理完毕后，等待页面稳定（无新弹窗弹出）再进行后续截图操作
     f. 每次切换分辨率后，如果弹窗再次出现，重复上述循环关闭操作

2. 创建报告目录
   - 在当前工作目录下创建 `responsive-report/` 目录
   - 根据目标页面 URL 生成子文件夹名称，格式为 `{host}/{path}`：
     - 第一级目录：使用 host 部分（域名+端口），端口号用 `_` 连接（如 `localhost_8004`、`51cg1.com`）
     - 第二级目录：使用 pathname 部分，将 `/` 替换为 `_`，去掉首尾的 `_`；如果 pathname 为空或仅为 `/`，则使用 `home`
     - 示例：`http://localhost:8004/about` → `responsive-report/localhost_8004/about/`
     - 示例：`http://localhost:8004/products/detail` → `responsive-report/localhost_8004/products_detail/`
     - 示例：`http://localhost:8004/` → `responsive-report/localhost_8004/home/`
     - 示例：`https://51cg1.com/` → `responsive-report/51cg1.com/home/`
     - 示例：`https://51cg1.com/news` → `responsive-report/51cg1.com/news/`
   - 截图和报告文件存放在该子文件夹中

3. 逐一切换分辨率并截图（含滚动截图）
   - 按上述分辨率列表，依次调整浏览器视口大小
   - 每个分辨率下执行以下操作：
     a. 先滚动到页面顶部（scrollTo(0,0)），截取首屏视口截图
     b. 使用 `mcp__playwright__browser_evaluate` 获取页面总高度：`document.body.scrollHeight`
     c. 如果页面高度 > 视口高度的 2 倍，进行滚动截图：
        - 每次滚动 100% 视口高度（即一整屏），确保每张截图对应一屏完整内容
        - 每滚动一次截取一张视口截图
        - 持续滚动直到到达页面底部
        - 截图文件名格式：`{设备名}-{宽}x{高}-scroll{序号}.png`
     d. 如果页面高度较短（<= 2 倍视口），只截取首屏即可
   - 截图保存到 `responsive-report/{url子文件夹}/` 目录下
   - 截图过程中简要汇报进度（如"1/6 iPhone SE - 首屏 + 3张滚动截图"）

4. 分析每个分辨率下的页面表现（含滚动内容）
   - **首屏截图检查**：
     - 导航栏/菜单是否正常（是否换行、溢出、被截断）
     - 首屏内容是否合理（非大量广告占据）
     - 是否有水平溢出
     - 文字是否可读
   - **滚动截图逐张检查**（非常重要，每张都必须认真审查截图内容）：
     - 文字是否可读（过小或被截断）
     - 图片是否正常缩放或溢出容器
     - 元素是否有重叠或错位
     - 广告横幅是否占据过多空间（超过半屏以上视为问题）
     - 广告是否遮挡正文内容
     - 底部 footer 是否正常显示
     - 是否有固定定位元素遮挡内容（如 fixed header/底部浮窗）
     - 内容卡片之间间距是否异常（过大的空白区域）
     - 侧栏在小屏下是否正确折叠或隐藏
   - **关键要求：对每张有问题的滚动截图，必须记录**：
     a. 属于哪个设备、第几屏（scroll 序号）
     b. 问题区域在截图中的位置（top%、left%、width%、height%）
     c. 问题简述（用于标注框标签）
     d. 对应的修复建议（写入 issue）
   - 无问题的滚动截图不需要标注，但有问题的必须全部标注出来

5. 生成标注配置文件 `annotations.conf`
   - 根据步骤 4 的分析结果，使用 Write 工具在截图目录下生成 `annotations.conf` 文件
   - 该文件驱动报告中的评价徽章、红色标注框、问题与建议等内容
   - **文件格式说明**（每行一条，`#` 开头为注释，空行跳过）：

     ```
     # 【设备评价】eval|设备文件名前缀|ok/warn/error|问题简述
     eval|iphone-se-375x667|warn|固定顶栏占位较多；广告面积过大
     eval|desktop-1920x1080|ok|布局正常，导航单行完整显示

     # 【首屏标注框】anno|设备文件名前缀|top%|left%|width%|height%|标签文字
     anno|ipad-mini-768x1024|0|10|90|19|导航菜单多行堆叠

     # 【滚动截图标注框】scroll_anno|设备文件名前缀|scroll序号(从1开始)|top%|left%|width%|height%|标签文字
     # scroll序号对应 scroll1.png=1, scroll2.png=2, ...
     scroll_anno|iphone-se-375x667|4|12|2|96|30|广告横幅占据整屏
     scroll_anno|iphone-se-375x667|2|60|0|100|35|图片溢出容器
     scroll_anno|ipad-mini-768x1024|1|0|10|50|18|导航始终多行堆叠
     scroll_anno|laptop-1366x768|3|40|0|100|20|空白区域过大

     # 【问题与建议】issue|序号|标题|问题描述|优化建议
     # 每个标注框对应的问题都应有一条 issue，可合并同类问题
     issue|1|导航栏在 768px 下多行堆叠|在 iPad Mini 分辨率下导航换行堆叠。|在 768px 断点处切换为汉堡菜单。
     issue|2|移动端广告占据过多空间|广告横幅在手机端占据近一整屏高度。|缩小广告尺寸或降低广告密度。
     ```

   - **设备文件名前缀**：必须与截图文件名前缀一致（即 `{前缀}-scroll0.png` 中的前缀部分）
   - **标注框坐标**：使用百分比，相对于截图图片区域定位。估算方法：观察截图中问题区域大致占据的位置和面积比例
   - **评价等级**：`ok` = 绿色布局正常，`warn` = 黄色有问题，`error` = 红色严重问题
   - 每个有问题的设备都应该有对应的 `eval` 行和至少一个 `anno` / `scroll_anno` 行
   - **滚动截图标注要求**：
     - 步骤 4 中发现有问题的每张滚动截图，都必须有对应的 `scroll_anno` 行
     - scroll 序号从 1 开始，对应 `{前缀}-scroll1.png` = 1, `{前缀}-scroll2.png` = 2, ...
     - 同一张滚动截图可以有多个标注框（多行 `scroll_anno`，序号相同）
     - 每个滚动问题都应有对应的 `issue` 行（可合并同类问题为一条 issue）
   - 布局正常的设备只需 `eval` 行即可（会在卡片底部显示绿色"布局正常"徽章）
   - `issue` 行汇总所有发现的问题（含首屏和滚动），给出具体描述和修复建议

6. 调用脚本生成 HTML 报告
   - `{SKILL_DIR}` 是本 skill 文件所在目录（即 `Base directory for this skill` 的值），执行时替换为实际路径
   - 使用 Bash 执行 skill 目录下的报告生成脚本：
     ```bash
     bash "{SKILL_DIR}/generate-report.sh" "responsive-report/{url子文件夹}" "{页面URL}"
     ```
   - 脚本会自动：
     a. 扫描目录中的截图文件，按文件名前缀识别设备
     b. 读取 `annotations.conf`，生成带评价徽章、红色标注框、问题建议的 HTML
     c. 将截图 base64 内嵌到 HTML 中，确保报告自包含
     d. 输出 `index.html` 并自动在浏览器中打开
   - **不要手动拼接 HTML**，必须通过脚本生成
   - 脚本生成的报告包含以下功能：
     - 汇总表格（设备、分辨率、评价、问题描述）
     - 首屏截图卡片（带红色标注框标注问题区域）
     - 发现的问题与优化建议区块
     - 滚动截图按设备折叠展示（有问题的滚动截图也带标注框）
     - Lightbox 点击放大（滚轮缩放、双击复位、ESC 关闭）
   - 告知用户报告文件的保存路径

## 工具使用要求

- 使用 `mcp__playwright__browser_resize` 切换分辨率
- 使用 `mcp__playwright__browser_take_screenshot` 截图
- 使用 `mcp__playwright__browser_snapshot` 检查页面结构
- 使用 `mcp__playwright__browser_evaluate` 获取页面高度和执行滚动：
  - 获取高度：`document.body.scrollHeight`
  - 执行滚动：`window.scrollTo(0, {目标位置})`
  - 滚动后等待内容渲染：每次滚动后截图前等待片刻（Playwright 会自动等待）
- 使用 `Write` 生成 `annotations.conf` 标注配置文件
- 使用 `Bash` 调用 `~/.claude/skills/responsive-check/generate-report.sh` 脚本生成 HTML 报告
- **不要手动拼接或 Write HTML 报告文件**，必须通过脚本生成
- 不要修改项目代码
- 滚动截图数量控制：每个分辨率最多截取 5 张滚动截图（不含首屏），避免报告文件过大

## 截图文件命名规范

脚本通过文件名前缀自动识别设备，截图必须按以下格式命名：
- 首屏：`{前缀}-scroll0.png`
- 滚动：`{前缀}-scroll1.png`, `{前缀}-scroll2.png`, ...

支持的前缀与设备映射：
| 文件名前缀 | 识别为 |
|-----------|-------|
| `iphone-se-375x667` | iPhone SE (375×667) |
| `iphone14-390x844` | iPhone 14 (390×844) |
| `ipad-mini-768x1024` | iPad Mini (768×1024) |
| `ipad-pro-1024x1366` | iPad Pro (1024×1366) |
| `laptop-1366x768` | 笔记本 (1366×768) |
| `desktop-1920x1080` | 桌面 (1920×1080) |

也支持 `{宽}x{高}` 格式的自定义命名（如 `480x320-scroll0.png`）。
