using System.Collections.Generic;

namespace NuGetPackageManager.Options
{
    public class DeprecationOptions : INugetApiOptions
    {
        public DeprecationOptions(string apiKey, string packageId, IEnumerable<string> versions, string message, bool force, bool undo, bool deprecateAllExceptLatest = false, bool whatIf = false)
        {
            this.ApiKey = apiKey;
            this.Versions = versions;
            this.Message = message;
            this.PackageId = packageId;
            this.Force = force;
            this.Undo = undo;
            this.DeprecateAllExceptLatest = deprecateAllExceptLatest;
            this.WhatIf = whatIf;
        }

        public string ApiKey { get; set; }

        public string PackageId { get; set; }

        public bool Force { get; private set; }
        
        public IEnumerable<string> Versions { get; set; }

        public string Message { get; set; }

        public bool Undo { get; set; }
        
        /// <summary>
        /// When true, all versions except the latest will be deprecated.
        /// The Versions property will be populated automatically if empty.
        /// </summary>
        public bool DeprecateAllExceptLatest { get; set; }
        
        /// <summary>
        /// When true, shows which packages and versions would be deprecated without actually performing the operation.
        /// </summary>
        public bool WhatIf { get; set; }
    }
}
