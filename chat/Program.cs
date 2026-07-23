using System.Net.Http.Json;
using System.Text.Json;

var baseUrl = (Environment.GetEnvironmentVariable("AGENT_URL") ?? "http://localhost:8088").TrimEnd('/');
const string defaultPrompt = "Create a concise daily repo digest for microsoft/agent-framework.";
using var httpClient = new HttpClient();

Console.WriteLine("=== Daily Repo Digest Agent Chat ===");
Console.WriteLine($"Endpoint: {baseUrl}/responses");
Console.WriteLine($"Press Enter to use: {defaultPrompt}");
Console.WriteLine("Type 'exit' or 'quit' to end.");
Console.WriteLine();

while (true)
{
    Console.Write("You: ");
    var input = Console.ReadLine();
    if (input is null)
    {
        break;
    }

    var message = input.Trim();
    if (message.Equals("exit", StringComparison.OrdinalIgnoreCase) ||
        message.Equals("quit", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine("Goodbye!");
        break;
    }

    if (message.Length == 0)
    {
        message = defaultPrompt;
    }

    try
    {
        using var response = await httpClient.PostAsJsonAsync(
            $"{baseUrl}/responses",
            new { input = message, stream = false });
        response.EnsureSuccessStatusCode();
        using var payload = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync());
        Console.WriteLine($"\nAgent: {ExtractResponseText(payload.RootElement)}\n");
    }
    catch (Exception exception)
    {
        Console.WriteLine($"\nError: {exception.Message}\n");
    }
}

static string ExtractResponseText(JsonElement response)
{
    if (response.TryGetProperty("output_text", out var outputText) &&
        outputText.ValueKind == JsonValueKind.String)
    {
        return outputText.GetString()!;
    }

    if (response.TryGetProperty("output", out var output) &&
        output.ValueKind == JsonValueKind.Array)
    {
        foreach (var item in output.EnumerateArray())
        {
            if (!item.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var part in content.EnumerateArray())
            {
                if (part.TryGetProperty("type", out var type) &&
                    (type.GetString() is "output_text" or "text") &&
                    part.TryGetProperty("text", out var text) &&
                    text.ValueKind == JsonValueKind.String)
                {
                    return text.GetString()!;
                }
            }
        }
    }

    return response.GetRawText();
}
