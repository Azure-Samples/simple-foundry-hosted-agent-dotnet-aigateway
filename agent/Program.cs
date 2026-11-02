using DotNetEnv;
using Microsoft.Agents.AI.Foundry.Hosting;
using RepoDigestAgent;

Env.NoClobber().TraversePath().Load();

var builder = WebApplication.CreateBuilder(args);
var credential = DailyRepoDigestAgent.CreateAzureCredential(builder.Configuration);

builder.Services.AddFoundryResponses(DailyRepoDigestAgent.Build(builder.Configuration, credential));
builder.Services.AddFoundryToolboxes(
    credential,
    DailyRepoDigestAgent.ToolboxName(builder.Configuration));

var app = builder.Build();
app.MapFoundryResponses();
app.Run();

public partial class Program;
