# DeprecateAspirePackages.ps1
# This script searches for NuGet packages matching specific patterns and deprecates all versions except the latest
#
# WORKFLOW:
#   1. Generate a plan:    .\DeprecateAspirePackages.ps1 -GeneratePlan -OutputFile deprecation-plan.json
#   2. Review and edit:    Open deprecation-plan.json and modify as needed
#   3. Apply the plan:     .\DeprecateAspirePackages.ps1 -ApplyPlan deprecation-plan.json -ApiKey <your-key>
#
# In the plan JSON, you can:
#   - Change "action" from "deprecate" to "skip" to skip a package
#   - Remove specific versions from "versionsToDeprecate" array
#   - Set a custom "message" per package (null = use defaultMessage)
#   - Delete package entries entirely

# Parameters
param(
    [Parameter(Mandatory=$false)]
    [string]$ApiKey,
    
    [Parameter(Mandatory=$false)]
    [string]$DeprecationMessage = "This version is out of support and is no longer maintained. Please upgrade to the latest version. See our support policy for details: https://aka.ms/dotnet/aspire/support",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$GeneratePlan,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "deprecation-plan.json",
    
    [Parameter(Mandatory=$false)]
    [string]$ApplyPlan,
    
    [Parameter(Mandatory=$false)]
    [string]$LatestVersionPrefix
)

# Define the search patterns for packages (only Aspire.* now)
$packagePatterns = @("Aspire.*")

# Function to get all versions of a specific package
function Get-PackageVersions {
    param (
        [string]$PackageId
    )
    
    try {
        $indexUrl = "https://api.nuget.org/v3/index.json"
        $index = Invoke-RestMethod -Uri $indexUrl -Method Get
        
        # Find the package base address service
        $packageBaseAddress = $index.resources | Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } | Select-Object -First 1
        if (-not $packageBaseAddress) {
            throw "Could not find PackageBaseAddress service in the NuGet API index"
        }
        
        $baseUrl = $packageBaseAddress.'@id'
        $packageIdLower = $PackageId.ToLowerInvariant()
        $versionsUrl = "$($baseUrl)$($packageIdLower)/index.json"
        
        $versionsResponse = Invoke-RestMethod -Uri $versionsUrl -Method Get
        return $versionsResponse.versions
    } catch {
        Write-Warning "Error getting versions for package $PackageId : $_"
        return @()
    }
}

# Function to get deprecation status for all versions of a package
function Get-PackageDeprecationStatus {
    param (
        [string]$PackageId
    )
    
    try {
        $indexUrl = "https://api.nuget.org/v3/index.json"
        $index = Invoke-RestMethod -Uri $indexUrl -Method Get
        
        # Find the registration base URL (contains deprecation metadata)
        $registrationService = $index.resources | Where-Object { $_.'@type' -eq 'RegistrationsBaseUrl/3.6.0' } | Select-Object -First 1
        if (-not $registrationService) {
            # Fall back to older registration service
            $registrationService = $index.resources | Where-Object { $_.'@type' -like 'RegistrationsBaseUrl*' } | Select-Object -First 1
        }
        
        if (-not $registrationService) {
            Write-Warning "Could not find RegistrationsBaseUrl service - skipping deprecation check"
            return @{}
        }
        
        $baseUrl = $registrationService.'@id'
        $packageIdLower = $PackageId.ToLowerInvariant()
        $registrationUrl = "$($baseUrl)$($packageIdLower)/index.json"
        
        $registrationResponse = Invoke-RestMethod -Uri $registrationUrl -Method Get
        
        $deprecationInfo = @{}
        
        # The registration response contains pages of catalog entries
        foreach ($page in $registrationResponse.items) {
            # Some pages are inline, others need to be fetched
            $items = $page.items
            if (-not $items -and $page.'@id') {
                # Need to fetch the page
                $pageResponse = Invoke-RestMethod -Uri $page.'@id' -Method Get
                $items = $pageResponse.items
            }
            
            if ($items) {
                foreach ($item in $items) {
                    $catalogEntry = $item.catalogEntry
                    if ($catalogEntry) {
                        $version = $catalogEntry.version
                        $deprecation = $catalogEntry.deprecation
                        
                        if ($deprecation) {
                            $deprecationInfo[$version] = @{
                                IsDeprecated = $true
                                Message = $deprecation.message
                                Reasons = $deprecation.reasons
                                AlternatePackage = $deprecation.alternatePackage
                            }
                        } else {
                            $deprecationInfo[$version] = @{
                                IsDeprecated = $false
                            }
                        }
                    }
                }
            }
        }
        
        return $deprecationInfo
    } catch {
        Write-Warning "Error getting deprecation status for package $PackageId : $_"
        return @{}
    }
}

# Function to parse and sort NuGet versions properly
function Sort-NuGetVersions {
    param (
        [string[]]$Versions
    )
    
    # Parse versions and sort them using semantic versioning logic
    $parsed = $Versions | ForEach-Object {
        $v = $_
        try {
            # Handle versions like "8.0.0-preview.1.23456.7"
            $parts = $v -split '-', 2
            $mainParts = $parts[0] -split '\.'
            $prerelease = if ($parts.Length -gt 1) { $parts[1] } else { $null }
            
            [PSCustomObject]@{
                Original = $v
                Major = [int]$mainParts[0]
                Minor = if ($mainParts.Length -gt 1) { [int]$mainParts[1] } else { 0 }
                Patch = if ($mainParts.Length -gt 2) { [int]$mainParts[2] } else { 0 }
                Build = if ($mainParts.Length -gt 3) { [int]$mainParts[3] } else { 0 }
                Prerelease = $prerelease
                IsPrerelease = $null -ne $prerelease
            }
        } catch {
            # If parsing fails, treat as lowest priority
            [PSCustomObject]@{
                Original = $v
                Major = 0
                Minor = 0
                Patch = 0
                Build = 0
                Prerelease = $v
                IsPrerelease = $true
            }
        }
    }
    
    # Sort: higher versions first, stable versions before prereleases of the same base version
    $sorted = $parsed | Sort-Object -Property Major, Minor, Patch, Build, IsPrerelease, Prerelease -Descending
    return $sorted | Select-Object -ExpandProperty Original
}

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

# Function to generate a deprecation plan
function New-DeprecationPlan {
    param (
        [string[]]$PackageIds,
        [string]$DefaultMessage,
        [string]$VersionPrefix
    )
    
    Write-Host "`nGenerating deprecation plan for $($PackageIds.Count) packages..."
    if ($VersionPrefix) {
        Write-Host "Filtering by latest version prefix: '$VersionPrefix'"
        Write-Host "  - Packages where latest version starts with '$VersionPrefix' will default to 'deprecate'"
        Write-Host "  - Other packages will default to 'skip'"
    }
    
    $packages = @()
    $totalPackages = $PackageIds.Count
    $current = 0
    $totalAlreadyDeprecated = 0
    $matchedByVersionPrefix = 0
    $skippedByVersionPrefix = 0
    
    foreach ($packageId in $PackageIds) {
        $current++
        Write-Progress -Activity "Fetching package versions and deprecation status" -Status "$packageId ($current of $totalPackages)" -PercentComplete (($current / $totalPackages) * 100)
        
        $versions = Get-PackageVersions -PackageId $packageId
        
        if ($versions -and $versions.Count -gt 0) {
            $sortedVersions = Sort-NuGetVersions -Versions $versions
            $latestVersion = $sortedVersions[0]
            $olderVersions = if ($sortedVersions.Count -gt 1) { $sortedVersions[1..($sortedVersions.Count - 1)] } else { @() }
            
            # Determine action based on version prefix filter
            $action = "deprecate"
            if ($VersionPrefix) {
                if ($latestVersion.StartsWith($VersionPrefix)) {
                    $action = "deprecate"
                    $matchedByVersionPrefix++
                } else {
                    $action = "skip"
                    $skippedByVersionPrefix++
                }
            }
            
            # Get deprecation status for all versions
            $deprecationStatus = Get-PackageDeprecationStatus -PackageId $packageId
            
            # Separate versions into those that need deprecation and those already deprecated
            $versionsToDeprecate = @()
            $alreadyDeprecatedVersions = @()
            
            foreach ($version in $olderVersions) {
                $status = $deprecationStatus[$version]
                if ($status -and $status.IsDeprecated) {
                    $alreadyDeprecatedVersions += [PSCustomObject]@{
                        version = $version
                        existingMessage = $status.Message
                        reasons = $status.Reasons
                    }
                    $totalAlreadyDeprecated++
                } else {
                    $versionsToDeprecate += $version
                }
            }
            
            $packages += [PSCustomObject]@{
                packageId = $packageId
                latestVersion = $latestVersion
                versionsToDeprecate = @($versionsToDeprecate)
                alreadyDeprecated = @($alreadyDeprecatedVersions)
                message = $null  # null means use defaultMessage
                action = $action
            }
        } else {
            Write-Warning "No versions found for package $packageId - skipping"
        }
    }
    
    Write-Progress -Activity "Fetching package versions and deprecation status" -Completed
    
    $plan = [PSCustomObject]@{
        generatedAt = (Get-Date).ToString("o")
        defaultMessage = $DefaultMessage
        latestVersionPrefixFilter = $VersionPrefix
        packages = $packages
    }
    
    # Print summary of already deprecated versions
    if ($totalAlreadyDeprecated -gt 0) {
        Write-Host "`n[INFO] Found $totalAlreadyDeprecated versions already deprecated - these will be excluded from the plan."
    }
    
    # Print summary of version prefix filtering
    if ($VersionPrefix) {
        Write-Host "`n[INFO] Version prefix filter '$VersionPrefix' results:"
        Write-Host "  - Packages matched (action=deprecate): $matchedByVersionPrefix"
        Write-Host "  - Packages not matched (action=skip): $skippedByVersionPrefix"
    }
    
    return $plan
}

# Function to apply a deprecation plan
function Invoke-DeprecationPlan {
    param (
        [PSCustomObject]$Plan,
        [string]$ApiKey,
        [bool]$WhatIfMode
    )
    
    $packagesToProcess = $Plan.packages | Where-Object { $_.action -eq "deprecate" -and $_.versionsToDeprecate.Count -gt 0 }
    
    if ($packagesToProcess.Count -eq 0) {
        Write-Host "No packages to deprecate in the plan."
        return
    }
    
    Write-Host "`nProcessing $($packagesToProcess.Count) packages for deprecation..."
    
    foreach ($pkg in $packagesToProcess) {
        $message = if ($pkg.message) { $pkg.message } else { $Plan.defaultMessage }
        
        Write-Host "`n=========================================="
        Write-Host "Package: $($pkg.packageId)"
        Write-Host "Latest Version (keeping): $($pkg.latestVersion)"
        Write-Host "Versions to deprecate: $($pkg.versionsToDeprecate.Count)"
        Write-Host "Message: $message"
        Write-Host "==========================================`n"
        
        Set-PackageDeprecation -PackageId $pkg.packageId -ApiKey $ApiKey -Message $message -Versions $pkg.versionsToDeprecate -WhatIfMode $WhatIfMode
    }
}

# Function to deprecate package versions
function Set-PackageDeprecation {
    param (
        [string]$PackageId,
        [string]$ApiKey,
        [string]$Message,
        [string[]]$Versions,
        [bool]$WhatIfMode
    )
    
    Write-Host "`nProcessing package: $PackageId"
    
    # If specific versions are provided, use them; otherwise fall back to deprecateAllExceptLatest
    if ($Versions -and $Versions.Count -gt 0) {
        $versionsArg = $Versions -join ","
        $arguments = @(
            "run",
            "--",
            "deprecate",
            "--packageId", "$PackageId",
            "--versions", "$versionsArg",
            "--apiKeys", "$ApiKey",
            "--message", "$Message"
        )
    } else {
        $arguments = @(
            "run",
            "--",
            "deprecate",
            "--packageId", "$PackageId",
            "--deprecateAllExceptLatest",
            "--apiKeys", "$ApiKey",
            "--message", "$Message"
        )
    }
    
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

# Mode 1: Generate Plan
if ($GeneratePlan) {
    Write-Host "Running in PLAN GENERATION mode..."
    Write-Host "Output will be written to: $OutputFile"
    
    # Search for packages matching each pattern
    $packagesToProcess = @()
    foreach ($pattern in $packagePatterns) {
        $matchingPackages = Search-NuGetPackages -Pattern $pattern
        $packagesToProcess += $matchingPackages
    }
    
    # Remove duplicates
    $uniquePackages = $packagesToProcess | Select-Object -Unique | Sort-Object
    
    Write-Host "`nFound $($uniquePackages.Count) unique packages"
    
    if ($uniquePackages.Count -eq 0) {
        Write-Host "No packages found matching the specified patterns."
        exit
    }
    
    # Generate the plan
    $plan = New-DeprecationPlan -PackageIds $uniquePackages -DefaultMessage $DeprecationMessage -VersionPrefix $LatestVersionPrefix
    
    # Write the plan to file
    $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8
    
    Write-Host "`n=========================================="
    Write-Host "PLAN GENERATED SUCCESSFULLY"
    Write-Host "==========================================`n"
    Write-Host "Plan saved to: $OutputFile"
    Write-Host "Total packages in plan: $($plan.packages.Count)"
    
    $packagesToDeprecate = $plan.packages | Where-Object { $_.action -eq "deprecate" }
    $packagesToSkip = $plan.packages | Where-Object { $_.action -eq "skip" }
    $totalVersionsToDeprecate = ($packagesToDeprecate | ForEach-Object { $_.versionsToDeprecate.Count } | Measure-Object -Sum).Sum
    $totalAlreadyDeprecated = ($plan.packages | ForEach-Object { $_.alreadyDeprecated.Count } | Measure-Object -Sum).Sum
    
    Write-Host "Packages set to deprecate: $($packagesToDeprecate.Count)"
    Write-Host "Packages set to skip: $($packagesToSkip.Count)"
    Write-Host "Versions to deprecate: $totalVersionsToDeprecate"
    Write-Host "Versions already deprecated (excluded): $totalAlreadyDeprecated"
    
    if ($LatestVersionPrefix) {
        Write-Host "`nVersion prefix filter applied: '$LatestVersionPrefix'"
        Write-Host "Packages skipped (latest version doesn't match):"
        foreach ($pkg in $packagesToSkip) {
            Write-Host "  - $($pkg.packageId) (latest: $($pkg.latestVersion))"
        }
    }
    
    Write-Host "`nNext steps:"
    Write-Host "  1. Open '$OutputFile' and review the plan"
    Write-Host "  2. Modify as needed:"
    Write-Host "     - Set 'action' to 'skip' to skip a package"
    Write-Host "     - Set 'action' to 'deprecate' to include a skipped package"
    Write-Host "     - Remove versions from 'versionsToDeprecate' array"
    Write-Host "     - Set a custom 'message' per package (null = use default)"
    Write-Host "     - Delete package entries you don't want to process"
    Write-Host "     - Review 'alreadyDeprecated' to see what's already handled"
    Write-Host "  3. Apply the plan:"
    Write-Host "     .\DeprecateAspirePackages.ps1 -ApplyPlan '$OutputFile' -ApiKey <your-api-key>"
    Write-Host ""
    exit
}

# Mode 2: Apply Plan from file
if ($ApplyPlan) {
    Write-Host "Running in APPLY PLAN mode..."
    Write-Host "Reading plan from: $ApplyPlan"
    
    if (-not (Test-Path $ApplyPlan)) {
        Write-Error "Plan file not found: $ApplyPlan"
        exit 1
    }
    
    if (-not $ApiKey) {
        Write-Error "API key is required when applying a plan. Use -ApiKey parameter."
        exit 1
    }
    
    $plan = Get-Content -Path $ApplyPlan -Raw | ConvertFrom-Json
    
    $packagesToDeprecate = $plan.packages | Where-Object { $_.action -eq "deprecate" -and $_.versionsToDeprecate.Count -gt 0 }
    $packagesToSkip = $plan.packages | Where-Object { $_.action -eq "skip" -or $_.versionsToDeprecate.Count -eq 0 }
    
    Write-Host "`n=========================================="
    Write-Host "PLAN SUMMARY"
    Write-Host "==========================================`n"
    Write-Host "Packages to deprecate: $($packagesToDeprecate.Count)"
    Write-Host "Packages to skip: $($packagesToSkip.Count)"
    
    $totalVersionsToDeprecate = ($packagesToDeprecate | ForEach-Object { $_.versionsToDeprecate.Count } | Measure-Object -Sum).Sum
    Write-Host "Total versions to deprecate: $totalVersionsToDeprecate"
    
    if ($packagesToDeprecate.Count -eq 0) {
        Write-Host "`nNo packages to deprecate. Exiting."
        exit
    }
    
    Write-Host "`nPackages to be deprecated:"
    foreach ($pkg in $packagesToDeprecate) {
        Write-Host "  - $($pkg.packageId): $($pkg.versionsToDeprecate.Count) versions (keeping $($pkg.latestVersion))"
    }
    
    if ($packagesToSkip.Count -gt 0) {
        Write-Host "`nPackages being skipped:"
        foreach ($pkg in $packagesToSkip) {
            Write-Host "  - $($pkg.packageId)"
        }
    }
    
    # Confirm before proceeding (unless WhatIf mode)
    if (-not $WhatIf) {
        $confirmation = Read-Host "`nDo you want to proceed with deprecating versions of these packages? (y/n)"
        if ($confirmation -ne 'y') {
            Write-Host "Operation cancelled by user."
            exit
        }
    } else {
        Write-Host "`n[WHAT-IF MODE] - No actual changes will be made"
    }
    
    # Apply the plan
    Invoke-DeprecationPlan -Plan $plan -ApiKey $ApiKey -WhatIfMode $WhatIf.IsPresent
    
    Write-Host "`n=========================================="
    Write-Host "PLAN EXECUTION COMPLETED"
    Write-Host "==========================================`n"
    exit
}

# Mode 3: Legacy mode (direct execution without plan file)
Write-Host "Running in LEGACY mode (consider using -GeneratePlan for more control)..."

if (-not $ApiKey) {
    Write-Error "API key is required. Use -ApiKey parameter, or use -GeneratePlan to generate a plan first."
    exit 1
}

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
    Set-PackageDeprecation -PackageId $package -ApiKey $ApiKey -Message $DeprecationMessage -Versions @() -WhatIfMode $WhatIf.IsPresent
}

Write-Host "`nPackage deprecation process completed!"
