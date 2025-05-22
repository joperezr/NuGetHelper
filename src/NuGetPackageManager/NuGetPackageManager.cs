using NuGet.Common;
using NuGet.Protocol;
using NuGet.Protocol.Core.Types;
using NuGet.Versioning;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace NuGetPackageManager
{
    internal class NuGetPackageManager : IDisposable
    {
        private ILogger logger;
        private HttpClient client;

        public NuGetPackageManager(HttpClient client, ILogger logger)
        {
            this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
            this.client = client ?? throw new ArgumentNullException(nameof(client));
            this.client.BaseAddress = new Uri("https://www.nuget.org/api/v2/package/", UriKind.Absolute);
        }

        public async Task<IEnumerable<Tuple<string, NuGetVersion>>> GetPackageVersionsAsync(string packageName, CancellationToken cancellationToken)
        {
            var cache = new SourceCacheContext();
            var repository = Repository.Factory.GetCoreV3("https://api.nuget.org/v3/index.json");
            var resource = await repository.GetResourceAsync<FindPackageByIdResource>();

            IEnumerable<NuGetVersion> versions = await resource.GetAllVersionsAsync(
                packageName,
                cache,
                logger,
                cancellationToken);

            return versions.Select(version => Tuple.Create(packageName, version));
        }

        public async Task<IEnumerable<string>> GetAllVersionsExceptLatestAsync(string packageName, CancellationToken cancellationToken)
        {
            var packageVersions = await GetPackageVersionsAsync(packageName, cancellationToken);
            
            if (!packageVersions.Any())
            {
                logger.LogWarning($"No versions found for package {packageName}");
                return Array.Empty<string>();
            }
            
            // Find the latest version
            var orderedVersions = packageVersions.OrderByDescending(v => v.Item2).ToList();
            var latestVersion = orderedVersions.First().Item2;
            
            logger.LogInformation($"Latest version of {packageName} is {latestVersion}. This version will not be deprecated.");
            
            // Return all versions except the latest as strings
            return orderedVersions
                .Skip(1) // Skip the first (latest) version
                .Select(v => v.Item2.ToString())
                .ToList();
        }

        public async Task DeletePackageAsync(string packageName, NuGetVersion version, CancellationToken cancellationToken)
        {
            var package = $"{packageName} version {version}";
            this.logger.LogInformation($"Deleting package {package}");

            Uri deleteRequestUri = new Uri($"{packageName}/{version.ToString()}", UriKind.Relative);
            var response = await this.client.DeleteAsync(deleteRequestUri, cancellationToken);
            if (response.StatusCode == System.Net.HttpStatusCode.NoContent || response.StatusCode == System.Net.HttpStatusCode.OK)
            {
                this.logger.LogInformation($"Package {package} was removed successfully");
            }
            else
            {
                this.logger.LogWarning($"Removal failed for package {package} with code {response.StatusCode}");
            }
        }

        public async Task DeprecatePackagesAsync(string packageName, IEnumerable<string> versions, string deprecationMessage, CancellationToken cancellationToken)
        {
            var versionsString = String.Join(',', versions);
            logger.LogInformation($"Deprecating versions {versionsString} of package {packageName} ");
            var deprecationContext = new
            {
                versions = versions,
                isLegacy = true,
                hasCriticalBugs = false,
                isOther = true,
                //alternatePackageId = null,
                //alternatePackageVersion = context?.AlternatePackageVersion,
                message = deprecationMessage
            };

            var bodyJson = System.Text.Json.JsonSerializer.Serialize(deprecationContext);
            
            // Maximum number of retry attempts
            const int maxRetries = 3;
            int retryCount = 0;
            bool shouldRetry;
            
            do
            {
                shouldRetry = false;
                
                try
                {
                    var response = await this.client.PutAsync($"{packageName}/deprecations", new StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json"), cancellationToken);
                    
                    // Check if we need to retry due to throttling
                    shouldRetry = await HandleThrottlingAsync(response, $"deprecation of {packageName} versions {versionsString}", retryCount, maxRetries, cancellationToken);
                    if (shouldRetry)
                    {
                        retryCount++;
                        continue;
                    }
                    
                    // For other status codes, ensure the request was successful
                    response.EnsureSuccessStatusCode();
                    
                    // If we get here, the request was successful
                    logger.LogInformation($"Successfully deprecated versions {versionsString} of package {packageName}");
                }
                catch (TaskCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    // Operation was canceled by user
                    logger.LogWarning("Deprecation operation was canceled by user.");
                    throw;
                }
                catch (HttpRequestException ex) when (retryCount < maxRetries && 
                                                     (ex.Message.Contains("503") || // Service Unavailable
                                                      ex.Message.Contains("502") || // Bad Gateway
                                                      ex.Message.Contains("504")))  // Gateway Timeout
                {
                    // Handle temporary server errors with retry
                    retryCount++;
                    shouldRetry = true;
                    int waitSeconds = 30 * retryCount;
                    logger.LogWarning($"Server error occurred: {ex.Message}. Retrying in {waitSeconds} seconds. Attempt {retryCount} of {maxRetries}.");
                    await Task.Delay(TimeSpan.FromSeconds(waitSeconds), cancellationToken);
                }
                catch (Exception ex) when (retryCount >= maxRetries)
                {
                    // Log detailed error after all retries failed
                    logger.LogError($"Failed to deprecate versions {versionsString} of package {packageName} after {maxRetries} attempts. Error: {ex.Message}");
                    throw;
                }
            }
            while (shouldRetry && !cancellationToken.IsCancellationRequested);
        }

        private async Task<bool> HandleThrottlingAsync(HttpResponseMessage response, string operation, int retryCount, int maxRetries, CancellationToken cancellationToken)
        {
            // Check if we're being throttled (429 Too Many Requests)
            if (response.StatusCode == System.Net.HttpStatusCode.TooManyRequests)
            {
                // Check for Retry-After header
                if (response.Headers.TryGetValues("Retry-After", out var values) && values.FirstOrDefault() is string retryAfterValue)
                {
                    if (int.TryParse(retryAfterValue, out int retryAfterSeconds))
                    {
                        if (retryCount < maxRetries)
                        {
                            // Log that we're being throttled and will retry
                            logger.LogWarning($"Request throttled by NuGet API during {operation}. Waiting for {retryAfterSeconds} seconds before retry attempt {retryCount + 1} of {maxRetries}.");
                            
                            // Wait for the specified time before retrying
                            await Task.Delay(TimeSpan.FromSeconds(retryAfterSeconds), cancellationToken);
                            return true; // Should retry
                        }
                        else
                        {
                            // Log that we've reached the maximum retry attempts
                            logger.LogError($"Maximum retry attempts ({maxRetries}) reached after being throttled by the NuGet API during {operation}.");
                            throw new HttpRequestException($"Failed to complete {operation} after {maxRetries} retry attempts due to API throttling.");
                        }
                    }
                    else
                    {
                        // If we can't parse the Retry-After header, use default backoff strategy
                        if (retryCount < maxRetries)
                        {
                            int defaultWaitSeconds = 60 * (retryCount + 1); // Progressive backoff: 60s, 120s, 180s
                            logger.LogWarning($"Request throttled by NuGet API with invalid Retry-After value during {operation}. Using default wait of {defaultWaitSeconds} seconds before retry attempt {retryCount + 1} of {maxRetries}.");
                            await Task.Delay(TimeSpan.FromSeconds(defaultWaitSeconds), cancellationToken);
                            return true; // Should retry
                        }
                        else
                        {
                            logger.LogError($"Maximum retry attempts ({maxRetries}) reached after being throttled by the NuGet API during {operation}.");
                            throw new HttpRequestException($"Failed to complete {operation} after {maxRetries} retry attempts due to API throttling.");
                        }
                    }
                }
                else
                {
                    // No Retry-After header, use default backoff strategy
                    if (retryCount < maxRetries)
                    {
                        int defaultWaitSeconds = 60 * (retryCount + 1); // Progressive backoff: 60s, 120s, 180s
                        logger.LogWarning($"Request throttled by NuGet API without Retry-After header during {operation}. Using default wait of {defaultWaitSeconds} seconds before retry attempt {retryCount + 1} of {maxRetries}.");
                        await Task.Delay(TimeSpan.FromSeconds(defaultWaitSeconds), cancellationToken);
                        return true; // Should retry
                    }
                    else
                    {
                        logger.LogError($"Maximum retry attempts ({maxRetries}) reached after being throttled by the NuGet API during {operation}.");
                        throw new HttpRequestException($"Failed to complete {operation} after {maxRetries} retry attempts due to API throttling.");
                    }
                }
            }
            
            return false; // No need to retry for other status codes
        }

        public void Dispose()
        {
            this.client?.Dispose();
        }
    }
}
