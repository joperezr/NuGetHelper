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
