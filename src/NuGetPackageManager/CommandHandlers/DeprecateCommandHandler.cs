using NuGet.Common;
using NuGetPackageManager.Options;
using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace NuGetPackageManager.CommandHandlers
{
    internal class DeprecateCommandHandler : NugetCommandHandlerBase<DeprecationOptions>
    {
        public DeprecateCommandHandler(INugetApiOptions options, ILogger logger) : base(options, logger)
        {
        }

        protected override async Task Handle(NuGetPackageManager packageManager, DeprecationOptions options)
        {
            try
            {
                // If we're in the "deprecate all except latest" mode, we need to fetch all versions except the latest
                if (options.DeprecateAllExceptLatest)
                {
                    // If versions were provided but we're in the "all except latest" mode, warn the user
                    if (options.Versions != null && options.Versions.Any())
                    {
                        Logger.LogWarning("Versions list provided but deprecateAllExceptLatest flag is set. " +
                                          "The provided versions will be ignored.");
                    }
                    
                    // Get all versions except the latest
                    options.Versions = await packageManager.GetAllVersionsExceptLatestAsync(options.PackageId, CancellationToken.None);
                    
                    if (!options.Versions.Any())
                    {
                        Logger.LogInformation($"No versions to deprecate for package {options.PackageId}. " +
                                             "Either no versions exist or only the latest version exists.");
                        return;
                    }
                }
                
                // If WhatIf mode is enabled, just print what would happen
                if (options.WhatIf)
                {
                    Logger.LogInformation($"[WHAT-IF] The following versions of package {options.PackageId} would be deprecated:");
                    foreach (var version in options.Versions)
                    {
                        Logger.LogInformation($"[WHAT-IF] - Version {version}");
                    }
                    Logger.LogInformation($"[WHAT-IF] Deprecation message would be: \"{options.Message}\"");
                    Logger.LogInformation($"[WHAT-IF] No changes have been made. To perform the actual deprecation, run again without the --what-if switch.");
                    return;
                }
                
                // Otherwise perform the actual deprecation
                await packageManager.DeprecatePackagesAsync(options.PackageId, options.Versions, options.Message, CancellationToken.None);
                this.Logger.LogInformation($"Successfully deprecated versions {string.Join(',', options.Versions)} of package {options.PackageId}");
            }
            catch (Exception ex)
            {
                this.Logger.LogError($"Failed to deprecate versions {string.Join(',', options.Versions)} of package {options.PackageId}. Reason: {ex.Message}");
                throw;
            }
        }
    }
}
