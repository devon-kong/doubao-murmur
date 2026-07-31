using DoubaoMurmur.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace DoubaoMurmur.UI;

public sealed partial class HelpWindow : Window
{
    public HelpWindow(ToggleKey toggleKey)
    {
        InitializeComponent();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(hwnd));
        appWindow.Resize(new Windows.Graphics.SizeInt32(640, 620));

        Title = "Doubao Murmur - 使用帮助";
        BodyText.Text = BuildText(toggleKey);
    }

    private static string BuildText(ToggleKey toggleKey)
    {
        var keyName = toggleKey switch
        {
            ToggleKey.RightAlt => "右 Alt",
            ToggleKey.RightControl => "右 Ctrl",
            ToggleKey.RightShift => "右 Shift",
            ToggleKey.ScrollLock => "Scroll Lock",
            ToggleKey.Pause => "Pause",
            _ => toggleKey.ToString(),
        };

        return $"""
            快捷键
              {keyName}：开始 / 停止语音识别
              ESC：取消当前识别（不复制、不粘贴）

            使用流程
              1. 托盘菜单显示「状态：已登录」
              2. 把光标放到任意输入框
              3. 按一下 {keyName}，屏幕顶部出现悬浮窗，开始说话
              4. 悬浮窗实时显示识别到的文字
              5. 再按一下 {keyName} 结束，文字会自动复制并粘贴到输入框

            托盘菜单
              触发热键：换成右 Ctrl / 右 Shift / Scroll Lock / Pause
              拦截热键：让焦点窗口收不到该键。可避免按右 Alt 时唤出菜单栏，
                        但会同时禁用 AltGr，欧洲键盘布局请勿开启。
              开机自启：写入当前用户的启动项，不需要管理员权限
              打开日志：出问题时先看这里

            已知限制
              焦点在以管理员身份运行的窗口（任务管理器、管理员终端等）时，
              Windows 的 UIPI 机制会让本程序既收不到按键、也粘贴不进去。
              需要在这类窗口里使用时，请同样以管理员身份运行本程序。

            悬浮窗
              可以拖动，位置会被记住。它不会抢占焦点，
              所以识别结果始终粘贴到你原来的输入框。
            """;
    }
}
