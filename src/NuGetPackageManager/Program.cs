using NuGet.Common;
using NuGetPackageManager.Options;
using System;
using System.Collections.Generic;
using System.CommandLine;
using System.Threading;
using System.Threading.Tasks;

namespace NuGetPackageManager
{
    class Program
    {
        private const int DelayInMinutes = 1;
        static ILogger logger = new CompositeLogger();

        static async Task Main(string[] args)
        {
            var rootCommand = new RootCommand("NuGet package manager command-line app");
            var apiKeyOption = new Option<string>("--apiKeys", "Provide comma-separated list of PATs for the NuGet API account");
            //rootCommand.AddGlobalOption(apiKeyOption);

            rootCommand.Add(BuildUnlistCommand());
            rootCommand.Add(BuildDeprecateCommand());

            await rootCommand.InvokeAsync(args);
        }

        private static Command BuildDeprecateCommand()
        {
            var apiKeysOption = new Option<string>("--apiKeys", "Provide comma-separated list of PATs for the NuGet API account");
            apiKeysOption.IsRequired = true;
            var packageIdOption = new Option<string>("--packageId", "The name of the package to deprecate");
            packageIdOption.IsRequired = true;
            var versionsOptions = new Option<string>("--versions", "Comma separated list of package versions to deprecate. Not required if using --deprecateAllExceptLatest.");
            versionsOptions.IsRequired = false;
            var messageOption = new Option<string>("--message", "The deprecation message to show in NuGet.org for each of the versions to be deprecated.");
            messageOption.IsRequired = true;
            var deprecateAllExceptLatestOption = new Option<bool>("--deprecateAllExceptLatest", "When set, all versions except the latest will be deprecated. The --versions parameter is ignored in this case.");
            var whatIfOption = new Option<bool>("--what-if", "When set, shows which packages and versions would be deprecated without actually performing the operation.");

            var result = new Command("deprecate", "Deprecate specific versions of a specified package")
            {
                apiKeysOption,
                packageIdOption,
                versionsOptions,
                messageOption,
                deprecateAllExceptLatestOption,
                whatIfOption
            };

            //AddForceOption(result);

            //var undoOption = new Option<bool>("--undo", "Calls the underlying NuGet APIs to undo deprecation of the specified package.");
            //result.AddOption(undoOption);
            
            result.SetHandler(async (string apiKeys, string packageId, string versions, string message, bool deprecateAllExceptLatest, bool whatIf/*, bool force, bool undo*/) =>
            {
                if (string.IsNullOrWhiteSpace(apiKeys))
                {
                    logger.LogError("No API keys provided. Please provide at least one API key using the --apiKeys option.");
                    logger.LogInformation("Example: --apiKeys \"your-api-key-here\"");
                    return;
                }
                
                var keys = apiKeys.Split(',', StringSplitOptions.RemoveEmptyEntries);
                if (keys.Length == 0)
                {
                    logger.LogError("No valid API keys found. Please provide at least one non-empty API key using the --apiKeys option.");
                    logger.LogInformation("Example: --apiKeys \"your-api-key-here\"");
                    return;
                }
                
                foreach (var key in keys)
                {
                    var versionsList = deprecateAllExceptLatest ? 
                        Array.Empty<string>() : // We'll get them dynamically in the handler if using deprecateAllExceptLatest
                        (versions ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries);
                        
                    var deprecateOptions = new DeprecationOptions(key.Trim(), packageId, versionsList, message, true, false, deprecateAllExceptLatest, whatIf);
                    var handler = new CommandHandlers.DeprecateCommandHandler(deprecateOptions, logger);
                    if (await handler.TryHandle(deprecateOptions))
                        break;
                }
            }, apiKeysOption, packageIdOption, versionsOptions, messageOption, deprecateAllExceptLatestOption, whatIfOption);

            return result;
        }        private static Command BuildUnlistCommand()
        {
            var result = new Command("unlist", "Unlist all versions of the specified packages");

            var apiKeyOption = new Option<string>("--apiKey", "The API key used for package management");
            apiKeyOption.IsRequired = true;
            result.AddOption(apiKeyOption);

            var packageNamesOption = new Option<IEnumerable<string>>("--packages", "A comma-separated list of package names to unlist");
            packageNamesOption.IsRequired = true;
            result.AddOption(packageNamesOption);

            AddForceOption(result);

            result.SetHandler(async (string apiKey, IEnumerable<string> packageNames, bool force) =>
            {
                if (string.IsNullOrWhiteSpace(apiKey))
                {
                    logger.LogError("No API key provided. Please provide an API key using the --apiKey option.");
                    logger.LogInformation("Example: --apiKey \"your-api-key-here\"");
                    return;
                }

                var unlistOptions = new UnlistOptions(apiKey, packageNames, force);
                var handler = new CommandHandlers.UnlistCommandHandler(unlistOptions, logger);
                await handler.TryHandle(unlistOptions);
            });

            return result;
        }

        private static void AddForceOption(Command result)
        {
            var forceOption = new Option<bool>("--force", "Calls the underlying NuGet APIs to deprecate the package. Without this parameter (default) the command executes in `dry-run` mode.");
            result.AddOption(forceOption);
        }
    }
}
