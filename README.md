# NuGetHelper
A tool to help with NuGet package management

This utility is used to help with unlisting and deprecating NuGet packages.
It automates the process of unlisting individual versions of a given package and can also handle unlisting multiple packages at once.
Additionally, it can deprecate specific versions of a package or automatically deprecate all versions except the latest one.

## Unlist Command

The unlist command accepts the following set of parameters:

| Parameter name | Description | Required | Default value |
| --- | --- | --- | --- |
| apiKey | The API key used for package management | Yes | N / A |
| packages | Comma separated list of package names to unlist | Yes | N / A |
| force | By default (without this parameter) the command will execute in "read-only" mode, which will result in no packages being unlisted. It will simply print which packages and which versions would be unlisted. After you're sure about your intention, pass this flag explicitly as `--force` to run the actual unlisting. | No | false |

### Examples

This tool can be used to unlist all versions of one or more package. When using the tool, start without the `--force` parameter, to validate your intentions by running the following command:

#### Unlisting a single package

`NuGetPackageManager.exe --apiKey yourApiKeyGoesHere --packages yourPackageName`

If the list of package names and versions are indeed what you've expected to see, you can now append the `--force` argument in the end of the above command to unlist the `yourPackageName` package:

`NuGetPackageManager.exe --apiKey yourApiKeyGoesHere --packages yourPackageName --force`

#### Unlisting multiple packages

`NuGetPackageManager.exe --apiKey yourApiKeyGoesHere --packages packageName1,packageName2,packageName3`

If the list of package names and versions are indeed what you've expected to see, you can now append the `--force` argument in the end of the above command to unlist the packages:

`NuGetPackageManager.exe --apiKey yourApiKeyGoesHere --packages packageName1,packageName2,packageName3 --force`

## Deprecate Command

The deprecate command accepts the following set of parameters:

| Parameter name | Description | Required | Default value |
| --- | --- | --- | --- |
| apiKeys | Provide comma-separated list of PATs for the NuGet API account | **Required** | N / A |
| packageId | The name of the package to deprecate | **Required** | N / A |
| versions | Comma separated list of package versions to deprecate | No (if using deprecateAllExceptLatest) | N / A |
| message | The deprecation message to show in NuGet.org for each of the versions to be deprecated | **Required** | N / A |
| deprecateAllExceptLatest | When set, all versions except the latest will be automatically identified and deprecated | No | false |
| what-if | When set, shows which packages and versions would be deprecated without actually performing the operation | No | false |

### Deprecation Examples

#### Deprecating Specific Versions

To deprecate specific versions of a package:

```bash
NuGetPackageManager.exe deprecate --apiKeys yourApiKeyGoesHere --packageId yourPackageName --versions 1.0.0,1.1.0 --message "Please use the latest version instead"
```

#### Deprecating All Versions Except Latest

To automatically deprecate all versions except the latest one:

```bash
NuGetPackageManager.exe deprecate --apiKeys yourApiKeyGoesHere --packageId yourPackageName --deprecateAllExceptLatest --message "Please use the latest version instead"
```

This is useful when releasing a new version of a package, as it allows you to automatically deprecate all previous versions without having to specify them manually.

#### Using What-If Mode

To preview which packages and versions would be deprecated without actually performing the operation:

```bash
NuGetPackageManager.exe deprecate --apiKeys yourApiKeyGoesHere --packageId yourPackageName --deprecateAllExceptLatest --message "Please use the latest version instead" --what-if
```

The `--what-if` switch can be combined with any of the deprecation modes to see what would happen without making any actual changes. This is useful for verifying that the correct versions will be deprecated before running the command for real.

## Aspire Package Deprecation Workflow

The `DeprecateAspirePackages.ps1` script provides a two-phase workflow specifically designed for batch-deprecating Aspire packages with full control over what gets deprecated.

### Workflow Overview

1. **Generate a Plan** - Creates a JSON file listing all packages and versions that would be deprecated
2. **Review and Edit** - Manually review and modify the plan as needed
3. **Apply the Plan** - Execute the deprecations based on your edited plan

### Step 1: Generate a Plan

```powershell
.\DeprecateAspirePackages.ps1 -GeneratePlan -OutputFile deprecation-plan.json
```

This searches NuGet.org for all `Aspire.*` packages and creates a JSON file with the proposed deprecations.

### Step 2: Review and Edit the Plan

Open `deprecation-plan.json` and review/modify as needed:

```json
{
  "generatedAt": "2025-12-15T10:00:00Z",
  "defaultMessage": "This version is out of support...",
  "packages": [
    {
      "packageId": "Aspire.Hosting",
      "latestVersion": "9.0.0",
      "versionsToDeprecate": ["8.2.0", "8.1.0"],
      "alreadyDeprecated": [
        {
          "version": "8.0.0",
          "existingMessage": "Previously deprecated message",
          "reasons": ["Legacy"]
        }
      ],
      "message": null,
      "action": "deprecate"
    },
    {
      "packageId": "Aspire.Hosting.Redis",
      "latestVersion": "9.0.0",
      "versionsToDeprecate": ["8.2.0", "8.1.0"],
      "alreadyDeprecated": [],
      "message": "Custom message for this package",
      "action": "deprecate"
    }
  ]
}
```

> **Note:** The plan generator automatically checks NuGet.org for versions that are already deprecated and excludes them from `versionsToDeprecate`. These are listed in the `alreadyDeprecated` array for your reference, showing their existing deprecation message and reasons. This prevents accidentally overwriting custom deprecation messages.

**Editing options:**

| What you want to do | How to do it |
|---------------------|--------------|
| Skip a package entirely | Set `"action": "skip"` |
| Keep specific versions from deprecation | Remove them from `versionsToDeprecate` array |
| Use a custom message for a package | Set `"message": "Your custom message"` |
| Remove a package from processing | Delete the entire package entry |
| Use the default message | Keep `"message": null` |

### Step 3: Apply the Plan

```powershell
# Preview what will happen (recommended first)
.\DeprecateAspirePackages.ps1 -ApplyPlan deprecation-plan.json -ApiKey <your-api-key> -WhatIf

# Actually apply the deprecations
.\DeprecateAspirePackages.ps1 -ApplyPlan deprecation-plan.json -ApiKey <your-api-key>
```

### Script Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| `-GeneratePlan` | Generate a new deprecation plan | No |
| `-OutputFile` | Path for the generated plan file (default: `deprecation-plan.json`) | No |
| `-LatestVersionPrefix` | Only set `action=deprecate` for packages whose latest version starts with this prefix. Others default to `skip`. Useful for filtering to only packages you own. | No |
| `-ApplyPlan` | Path to a plan file to apply | No |
| `-ApiKey` | NuGet API key (required when applying) | For Apply |
| `-DeprecationMessage` | Default deprecation message | No |
| `-WhatIf` | Preview changes without applying | No |

### Filtering by Version Prefix

When you release Aspire packages, they all share the same version number (e.g., `9.0.0`). Third-party packages in the `Aspire.*` namespace (like `Aspire.Hosting.AWS`) will have different version numbers. Use `-LatestVersionPrefix` to automatically filter:

```powershell
# Only deprecate packages where latest version starts with "9.0"
.\DeprecateAspirePackages.ps1 -GeneratePlan -LatestVersionPrefix "9.0" -OutputFile deprecation-plan.json
```

This will:
- Set `action: "deprecate"` for packages like `Aspire.Hosting` (latest: `9.0.0`)
- Set `action: "skip"` for packages like `Aspire.Hosting.AWS` (latest: `1.2.3`)

You can still manually change the `action` in the JSON file before applying if needed.
