# DeprecateAspirePackages.ps1
# This script searches for NuGet packages matching specific patterns and deprecates all versions except the latest

# Parameters
param(
    [Parameter(Mandatory=$true)]
    [string]$ApiKey,
    
    [Parameter(Mandatory=$false)]
    [string]$DeprecationMessage = "This version is out of support and is no longer maintained. Please upgrade to the latest version. See our support policy for details: https://aka.ms/dotent/aspire/support",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Define the search patterns for packages
$packagePatterns = @("Aspire.*", "Microsoft.Extensions.ServiceDiscovery*")

# Function to search for packages matching a pattern using the official NuGet API
function Search-NuGetPackages {
    param (
        [string]$Pattern
    )
    
    Write-Host "Searching for packages matching pattern: $Pattern"
    
    try {
        # Use the official NuGet API to search for packages
        # First, get the search service URL from the NuGet API index
        $indexUrl = "https://api.nuget.org/v3/index.json"
        $index = Invoke-RestMethod -Uri $indexUrl -Method Get
        
        # Find the search query service URL
        $searchService = $index.resources | Where-Object { $_.'@type' -eq 'SearchQueryService' } | Select-Object -First 1
        if (-not $searchService) {
            throw "Could not find SearchQueryService in the NuGet API index"
        }
        
        $searchUrl = $searchService.'@id'
        $pageSize = 100  # Maximum page size allowed by NuGet API
        $allMatchingPackages = @()
        $page = 0
        $totalHits = 0
        
        # Fetch all pages of results
        do {
            # Construct the URL with paging parameters
            $fullSearchUrl = "$($searchUrl)?q=$Pattern&prerelease=true&semVerLevel=2.0.0&skip=$($page * $pageSize)&take=$pageSize"
            Write-Verbose "Fetching page $($page + 1) from $fullSearchUrl"
            
            $response = Invoke-RestMethod -Uri $fullSearchUrl -Method Get
            $totalHits = $response.totalHits
            
            # Filter results to match the pattern exactly
            if ($response.data -and $response.data.Count -gt 0) {
                $pageMatches = $response.data | Where-Object { $_.id -like $Pattern } | Select-Object -ExpandProperty id
                $allMatchingPackages += $pageMatches
                
                Write-Verbose "Page $($page + 1) returned $($pageMatches.Count) matching packages"
            }
            
            $page++
            
            # Check if we've processed all results
            $processedCount = $page * $pageSize
        } while ($processedCount -lt $totalHits)
        
        # Remove any possible duplicates
        $uniquePackages = $allMatchingPackages | Select-Object -Unique
        
        Write-Host "Found $($uniquePackages.Count) packages matching pattern: $Pattern"
        if ($uniquePackages.Count -gt 0) {
            return $uniquePackages
        } else {
            Write-Host "No packages found matching pattern: $Pattern"
            return @()
        }
    } catch {
        Write-Error "Error searching for packages: $_"
        return @()
    }
}

# Function to deprecate package versions
function Set-PackageDeprecation {
    param (
        [string]$PackageId,
        [string]$ApiKey,
        [string]$Message,
        [bool]$WhatIfMode
    )
    
    Write-Host "`nProcessing package: $PackageId"
    
    # Build the command line arguments
    $arguments = @(
        "run",
        "--",
        "deprecate",
        "--packageId", "$PackageId",
        "--deprecateAllExceptLatest",
        "--apiKeys", "$ApiKey",
        "--message", "$Message"
    )
    
    # Add WhatIf flag if specified
    if ($WhatIfMode) {
        $arguments += "--what-if"
    }
    
    # Execute the command
    try {
        $currentLocation = Get-Location
        $nugetPackageManagerPath = Join-Path $PSScriptRoot "src\NuGetPackageManager"
        
        Write-Host "Changing directory to: $nugetPackageManagerPath"
        Set-Location -Path $nugetPackageManagerPath
        
        Write-Host "Executing: dotnet $($arguments -join ' ')"
        & dotnet @arguments
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Command failed with exit code $LASTEXITCODE for package $PackageId"
        }
        
        Set-Location -Path $currentLocation
    } catch {
        Write-Error "Error executing command for package $PackageId : $_"
        Set-Location -Path $currentLocation
    }
}

# Main script execution
Write-Host "Starting package deprecation process..."

# Search for packages matching each pattern
$packagesToProcess = @()
foreach ($pattern in $packagePatterns) {
    $matchingPackages = Search-NuGetPackages -Pattern $pattern
    $packagesToProcess += $matchingPackages
}

# Remove duplicates
$uniquePackages = $packagesToProcess | Select-Object -Unique

Write-Host "`nFound $($uniquePackages.Count) unique packages to process"

if ($uniquePackages.Count -eq 0) {
    Write-Host "No packages found matching the specified patterns."
    exit
}

# Display the list of packages to be processed
Write-Host "`nPackages to be processed:"
$uniquePackages | ForEach-Object { Write-Host "- $_" }

# Confirm before proceeding
if (-not $WhatIf) {
    $confirmation = Read-Host "`nDo you want to proceed with deprecating versions of these packages? (y/n)"
    if ($confirmation -ne 'y') {
        Write-Host "Operation cancelled by user."
        exit
    }
}

# Process each package
foreach ($package in $uniquePackages) {
    Set-PackageDeprecation -PackageId $package -ApiKey $ApiKey -Message $DeprecationMessage -WhatIfMode $WhatIf.IsPresent
}

Write-Host "`nPackage deprecation process completed!"
