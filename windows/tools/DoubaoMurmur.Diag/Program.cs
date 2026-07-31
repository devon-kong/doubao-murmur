using DoubaoMurmur.Core;

// Console diagnostics for the parts of the app that need real hardware and real
// credentials. Running these first isolates "does Doubao accept a connection from
// Windows at all" from "is the WinUI shell wired up correctly".
//
//   DoubaoMurmur.Diag params        inspect stored credentials (no secrets printed)
//   DoubaoMurmur.Diag mic [seconds] check microphone capture and signal level
//   DoubaoMurmur.Diag asr [seconds] stream the microphone to Doubao and print results
//   DoubaoMurmur.Diag wav <file>    stream a WAV file instead of the microphone

var command = args.Length > 0 ? args[0].ToLowerInvariant() : "help";

return command switch
{
    "params" => ShowParams(),
    "mic" => await TestMicrophoneAsync(ParseSeconds(args, 1, 5)),
    "asr" => await TestAsrAsync(null, ParseSeconds(args, 1, 8)),
    "wav" => args.Length > 1
        ? await TestAsrAsync(args[1], 0)
        : Fail("用法: DoubaoMurmur.Diag wav <文件路径>"),
    _ => ShowHelp(),
};

// Parameter is not called 'args': that name is taken by the top-level program.
static int ParseSeconds(string[] argv, int index, int fallback) =>
    argv.Length > index && int.TryParse(argv[index], out var value) && value > 0 ? value : fallback;

static int ShowHelp()
{
    Console.WriteLine("""
        Doubao Murmur 诊断工具

          params        检查本地凭证是否存在（不会打印任何 cookie 值）
          mic [秒数]    测试麦克风采集，默认 5 秒
          asr [秒数]    用麦克风连接豆包并打印识别结果，默认 8 秒
          wav <文件>    改用 WAV 文件作为音频源

        凭证位置: %APPDATA%\doubao-murmur\asr_params.json
        """);
    return 0;
}

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}

static int ShowParams()
{
    Console.WriteLine($"凭证文件: {AppConfig.ParamsPath}");

    var parameters = AsrParamsStore.Load();
    if (parameters is null)
    {
        Console.WriteLine("未找到可用凭证。请先在主程序中登录豆包。");
        return 1;
    }

    // Cookie names only — the values are session credentials.
    Console.WriteLine($"cookie 数量 : {parameters.Cookies.Count}");
    Console.WriteLine($"cookie 名称 : {string.Join(", ", parameters.Cookies.Keys.Order())}");
    Console.WriteLine($"device_id   : {Mask(parameters.DeviceId)}");
    Console.WriteLine($"web_id      : {Mask(parameters.WebId)}");
    Console.WriteLine("凭证看起来完整。");
    return 0;
}

static string Mask(string value) =>
    value.Length <= 6 ? new string('*', value.Length) : value[..4] + new string('*', value.Length - 4);

static async Task<int> TestMicrophoneAsync(int seconds)
{
    Console.WriteLine($"采集 {seconds} 秒麦克风音频…");

    using var source = new WasapiMicSource();
    long totalBytes = 0;
    var peak = 0;

    try
    {
        source.Start(chunk =>
        {
            Interlocked.Add(ref totalBytes, chunk.Length);
            for (var i = 0; i + 1 < chunk.Length; i += 2)
            {
                var sample = Math.Abs(BitConverter.ToInt16(chunk, i));
                if (sample > peak) peak = sample;
            }
        });
    }
    catch (Exception ex)
    {
        return Fail($"麦克风启动失败: {ex.Message}");
    }

    await Task.Delay(TimeSpan.FromSeconds(seconds));
    source.Stop();

    var expected = (long)AppConfig.AudioSampleRate * 2 * seconds;
    Console.WriteLine($"收到 {totalBytes} 字节（预期约 {expected}）");
    Console.WriteLine($"峰值幅度 {peak} / 32767");

    if (totalBytes == 0) return Fail("没有采集到任何音频，请检查录音设备与麦克风隐私设置。");
    if (peak < 300) Console.WriteLine("警告: 信号非常微弱，说话时请再试一次。");
    return 0;
}

static async Task<int> TestAsrAsync(string? wavPath, int seconds)
{
    var parameters = AsrParamsStore.Load();
    if (parameters is null) return Fail("未找到可用凭证，请先在主程序中登录豆包。");

    using var client = new DoubaoAsrClient();
    var finished = new TaskCompletionSource();
    var lastText = string.Empty;

    client.Opened += () => Console.WriteLine("WebSocket 已连接");
    client.ResultReceived += text =>
    {
        lastText = text;
        Console.WriteLine($"识别中: {text}");
    };
    client.Finished += () =>
    {
        Console.WriteLine("收到 finish 事件");
        finished.TrySetResult();
    };
    client.ErrorOccurred += error =>
    {
        Console.Error.WriteLine($"连接错误: {error?.Message ?? "连接被关闭"}");
        finished.TrySetResult();
    };
    client.AuthErrorOccurred += () =>
    {
        Console.Error.WriteLine("鉴权失败: 凭证已过期，请重新登录。");
        finished.TrySetResult();
    };

    client.Connect(parameters);

    IAudioSource source;
    if (wavPath is not null)
    {
        if (!File.Exists(wavPath)) return Fail($"找不到文件: {wavPath}");
        Console.WriteLine($"回放 {wavPath}");
        var wav = new WavFileSource(wavPath);
        wav.Completed += () => Console.WriteLine("音频文件播放完毕");
        source = wav;
    }
    else
    {
        Console.WriteLine($"请开始说话，录音 {seconds} 秒…");
        source = new WasapiMicSource();
    }

    using (source)
    {
        try
        {
            source.Start(client.SendAudio);
        }
        catch (Exception ex)
        {
            return Fail($"音频源启动失败: {ex.Message}");
        }

        if (wavPath is not null)
        {
            // Give the file time to replay; WavFileSource paces itself in real time.
            while (source.IsCapturing) await Task.Delay(200);
        }
        else
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds));
        }

        source.Stop();
    }

    client.FinishSending();
    Console.WriteLine("等待最终结果…");
    await Task.WhenAny(finished.Task, Task.Delay(TimeSpan.FromSeconds(5)));
    client.Disconnect();

    if (string.IsNullOrEmpty(lastText)) return Fail("没有收到任何识别结果。");
    Console.WriteLine($"最终结果: {lastText}");
    return 0;
}
