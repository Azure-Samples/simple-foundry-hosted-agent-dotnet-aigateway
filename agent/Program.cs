using Azure.Identity;
using DotNetEnv;
using Microsoft.Agents.AI.Foundry.Hosting;
using RepoDigestAgent;

Env.NoClobber().TraversePath().Load();

var builder = WebApplication.CreateBuilder(args);
var credentialOptions = new DefaultAzureCredentialOptions
{
    ExcludeManagedIdentityCredential =
        string.IsNullOrWhiteSpace(builder.Configuration["FOUNDRY_HOSTING_ENVIRONMENT"])
};

builder.Services.AddFoundryResponses(DailyRepoDigestAgent.Build(builder.Configuration));
builder.Services.AddFoundryToolboxes(
    new DefaultAzureCredential(credentialOptions),
    DailyRepoDigestAgent.ToolboxName(builder.Configuration));

var app = builder.Build();
app.MapFoundryResponses();
app.Run();

public partial class Program;
