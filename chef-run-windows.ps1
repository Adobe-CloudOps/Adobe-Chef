# Filename:: chef-run-windows.ps1
# Author:: Tim Prendergast (<tprender@adobe.com>, @auxome)
# Copyright:: Copyright © 2013 Adobe Systems Incorporated
# License:: Apache License, Version 2.0
# Description:: OpsCode Chef Bootstrap Script for Windows Instances in AWS
# Notes:: At this time, AWS SDK built into images is still broken, so this is the brute-force way of doing things. Elegance coming soon...
# Requirements: 
#    Store the template files and the validator for your org in the AWS S3 bucket defined in bucketName.
#    Pass in user-data in this format:
#                 chef.role=<comma delimited set of role names>
#                 chef.env=<chef enviroment name>
#                 chef.org=<chef organization name>
#                 chef.id=<AWS Access Key for chef IAM user>             NOTE: This is used for accessing the S3 bucket to retrieve client files, so that is the only access this IAM user should require.
#                 chef.key=<AWS Secret Key for chef IAM user>            NOTE: This is used for accessing the S3 bucket to retrieve client files, so that is the only access this IAM user should require.
#                 bucketName=<name of s3 bucket where your client files.templates are located>
#    Set powershell execution policy to Unrestricted (Set-ExecutionPolicy Unrestricted) http://technet.microsoft.com/en-us/library/ee176949.aspx
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Define the latest chef release you want to run here... you can verify by putting "http://<omnibusBucketName>.s3.amazonaws.com<omnibusPath>" into your browser.
$omnibusBucketName = "opscode-omnibus-packages"
$omnibusPath = "/windows/2008r2/x86_64/chef-client-11.4.0-1.windows.msi"

# setup webClient object for use throughout script
$webClient = new-object system.net.webclient

# Base function to build S3 URLs for retrieving via Powershell Client. Files retrieved are: chef.rb, knife.rb, and validator file.
function buildUrl ($urlTypeRequested, $server, $bucketNameValue, $folderPath, $validatorFile, $templateDir, $clientTemplate, $knifeTemplate, $accessKey, $secretKey, $expireDate)
  {
    $s3BaseTime = [System.DateTime]::Parse("1970-01-01T00:00:00.0000000Z")
    $expires = [Convert]::ToInt32($expireDate.Subtract($s3BaseTime).TotalSeconds).ToString()
    $sha = new-object System.Security.Cryptography.HMACSHA1
    $utf8 = New-Object System.Text.utf8encoding
    $sha.Key = $utf8.Getbytes($secretKey)

    Write-Host "Entering Switch Loop for determining which string to sign..."
    switch ($urlTypeRequested)
    {
      chefClientTemplate {$stringToSign = "GET`n" + "`n" + "`n" + "$expires`n" + "$bucketNameValue" + "$templateDir" + "$clientTemplate"}
      chefKnifeTemplate {$stringToSign = "GET`n" + "`n" + "`n" + "$expires`n" + "$bucketNameValue" + "$templateDir" + "$knifeTemplate"}
      default {$stringToSign = "GET`n" + "`n" + "`n" + "$expires`n" + "$bucketNameValue" + "$folderPath" + "$validatorFile"}
    }
    Write-Host $urlTypeRequested

    $seedBytes = $utf8.GetBytes($stringToSign)
    $digest = $sha.ComputeHash($seedBytes)
    $base64Encoded = [Convert]::Tobase64String($digest)
    $null = [Reflection.Assembly]::LoadWithPartialName("System.Web")
    $urlEncoded = [System.Web.HttpUtility]::UrlEncode($base64Encoded)

    Write-Host "Entering switch statement to determine which URL to build..."
    switch ($urlTypeRequested)
      {
        chefClientTemplate {$fullUrl = $server + $bucketNameValue + $templateDir + $clientTemplate  + "?AWSAccessKeyId=" + $accessKey + "&Expires=" + $expires + "&Signature=" + $urlEncoded }
        chefKnifeTemplate {$fullUrl = $server + $bucketNameValue + $templateDir + $knifeTemplate + "?AWSAccessKeyId=" + $accessKey + "&Expires=" + $expires + "&Signature=" + $urlEncoded }
        default {$fullUrl = $server + $bucketNameValue + $folderPath + $validatorFile + "?AWSAccessKeyId=" + $accessKey + "&Expires=" + $expires + "&Signature=" + $urlEncoded }
      }
    Write-Host $fullUrl
    $fullUrl
  }

# This next codeblock does some prep-work -- make sure chef is installed, then setup some locations we need for this to automagically work.
# Check for the existence of a C:. If there is no c: root volume, my assumptions break and the script will fling itself off a cliff.
if (!(test-path c:\)) {
  Write-Host "No c:\, aborting run. Please make sure you have a mounted c: or tweak this script to look for your specified standard root drive."
  exit
}

# Check for c:\chef directory, if it doesn't exist let's create it and put the templates there.
if (!(test-path c:\chef)) {
  Write-Host "No chef config (c:\chef\) directory present, creating it..."
  mkdir c:\chef
  Write-Host "Done creating the c:\chef directory structure!"
}
if (!(test-path c:\chef\logs)) {
  mkdir c:\chef\logs
  Write-Host "Done creating the c:\chef\logs directory structure!"
}
# Check to see if chef-client is even installed
if (!(test-path c:\opscode\chef\bin\chef-client)) {
  Write-Host "No chef-client installed. I'll attempt to install it for you..."

  $url = "https://$omnibusBucketName.s3.amazonaws.com$omnibusPath"
    Write-Host $url
    Write-Host "Downloading chef omnibus package from $url..."

  $chefPackageTemp = $omnibusPath.tostring().split("/")
  $chefPackageCount = $chefPackageTemp.Count
  $chefPackage = $chefPackageTemp[$chefPackageCount-1]
  Write-Host "$chefPackageTemp -- $chefPackageCount -- $chefPackage..."
  $webClient.DownloadFile("$url","c:\chef\$chefPackage") 
  start -wait c:\chef\$chefPackage -ArgumentList '/passive /qb'
}

# Download the passed in user-data via EC2's metadata service: http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AESDG-chapter-instancedata.html
$awsurl = "http://169.254.169.254/latest/user-data"
$baseHostNameUrl = "http://169.254.169.254/latest/meta-data/public-hostname"
$instanceIdUrl = "http://169.254.169.254/latest/meta-data/instance-id"
$zoneUrl = "http://169.254.169.254/latest/meta-data/placement/availability-zone"
$targetfile = "c:\opscode\datafeed.txt"
$webClient.DownloadFile("$awsurl","$targetfile")

# Chef Variables we need to populate from the MetaData Service (via user-data). Powershell is stupid and apparently wont support splits inline with the base var assignment. LMK if you have a better idea here.
$baseHostName = $webclient.DownloadString($baseHostNameUrl)
$baseHostNameValue = $baseHostName.tostring().split(".")
$instanceId = $webclient.DownloadString($instanceIdUrl)
$zone = $webclient.DownloadString($zoneUrl)
$nodeName = $baseHostNameValue[0] + "." + $instanceId + "." + $zone
$chefRole = (Select-String "$targetfile" -pattern "chef.role")
$chefRoleValue = $chefRole.tostring().split("=")
$chefEnv = (Select-String "$targetfile" -pattern "chef.env")
$chefEnvValue = $chefEnv.tostring().split("=")
$chefOrg = (Select-String "$targetfile" -pattern "chef.org")
$chefOrgValue = $chefOrg.tostring().split("=")
$chefId = (Select-String "$targetfile" -pattern "chef.id")
$chefIdValue = $chefId.tostring().split("=")
$chefKey = (Select-String "$targetfile" -pattern "chef.key")
$chefKeyValue = $chefKey.tostring().split("=")
$chefServiceUrl = "https://api.opscode.com/organizations/" + $chefOrgValue[1]
$bucketName = (Select-String "$targetfile" -pattern "bucketName")
$bucketNameValue = $bucketName.tostring().split("=")

# debug output just so you can see what is running
Write-Host "baseHostName = $baseHostName"
Write-Host "instanceId = $instanceId"
Write-Host "zone = $zone"
Write-Host "nodeName = $nodeName"
Write-Host "Env Value = " $chefEnvValue[1]
Write-Host "Org Value = " $chefOrgValue[1]
Write-Host "ID Value = " $chefIdValue[1]
Write-Host "Key Value = " $chefKeyValue[1]
Write-Host "Role Value = " $chefRoleValue[1]
Write-Host "S3 Bucket Name = " $bucketNameValue[1]

# Structure the variables for the buildURL function
$server = "https://s3.amazonaws.com"
$bucketNameValue = "/" + $bucketNameValue[1]
$folderPath = "/" + $chefOrgValue[1]
$validatorFile = "/" + $chefOrgValue[1] + "-validator.pem"
$templateDir = "/templates"
$clientTemplate = "/client.rb.template"
$knifeTemplate = "/knife.rb.template"
$accessKey = $chefIdValue[1]
$secretKey = $chefKeyValue[1]
$expires = [System.DateTime]::Now.AddMinutes(5)

Write-Host $accessKey
Write-Host $secretKey

$url = buildUrl default $server $bucketNameValue $folderPath $validatorFile $templateDir $clientTemplate $knifeTemplate $accessKey $secretKey $expires
Write-Host $url
Write-Host "Downloading validator.pem file from S3..." 
$webClient.DownloadFile("$url","c:\chef\$validatorFile")

$url = buildUrl chefClientTemplate $server $bucketNameValue $folderPath $validatorFile $templateDir $clientTemplate $knifeTemplate $accessKey $secretKey $expires
Write-Host $url
Write-Host "Downloading client template from S3..."
$webClient.DownloadFile("$url","c:\chef\client.rb")

$url = buildUrl chefKnifeTemplate $server $bucketNameValue $folderPath $validatorFile $templateDir $clientTemplate $knifeTemplate $accessKey $secretKey $expires
Write-Host $url
Write-Host "Downloading knife template from S3..."
$webClient.DownloadFile("$url","c:\chef\knife.rb")


# Update config files based on the user-data we received
# First, we set the environment var based on what came in user-data. There should only be one environment ever passed. We make the assumption that we just take whatever comes in via userdata.
if (!$chefEnv -Or !$chefEnvValue)
  {
    Write-Host "I don't see a chefEnv or chefEnvValue -- contents output here: chefEnv=$chefEnv and chefEnvValue=$chefEnvValue"
    exit
  }
$chefEnvironment = "environment `t`"" + $chefEnvValue[1] + "`""

Write-Host "Setting environment variable in client.rb to $chefEnvValue"
Add-Content c:\chef\client.rb $chefEnvironment

# Next, we grab the roles and stuff them into the run_list. I assume the roles are already comma delimited. We may need to change this assumption later.
if (!$chefRole -Or !$chefRoleValue)
  {
    Write-Host "I don't see a chefRole or a chefRoleValue -- contents output here: chefRole=$chefRole and chefRoleValue=$chefRoleValue"
    exit
  }

# Build the run-list from the chef.role
  $run_list = "{ `"run_list`": [ "
  $hasrun = 0
  $runs = $chefRoleValue[1].tostring().split(",");
  $arlen = $runs.length - 1
  foreach ($run in $runs) {
    Write-Host "Run = $run, Length or Array = $arlen"
    if ($hasrun -lt $arlen) { 
           $run_list += "`"role[" + $run + "]`", "
           Write-Host $run_list 
           $hasrun += 1
      if ($hasrun -lt $arlen) { 
             $run_list += ", " 
         }
       } else {
           $run_list += "`"role[" + $run + "]`""
           Write-Host $run_list 
           $hasrun += 1
       }
  }
  $run_list += " ] }"

# Let's populate the knife.rb now
if (!$nodeName) 
  {
    Write-Host "No NodeName! Var contents: $nodeName`n"
    exit
  }

    $knifeNodeName = "node_name `t$nodeName"
    $chefServerUrl = "chef_server_url `t`"$chefServiceUrl`""
    $validationClientName = "validation_client_name `t`"" + $chefOrgValue[1] + "-validator`""
    $validationKey = "validation_key `t#{current_dir}/" + $chefOrgValue[1] + "-validator.pem"
    $fileCachePath = "file_cache_path `t`"c:/chef/logs`""
    Write-Host "Setting client node_name to $nodeName...`n"
    Write-Host "Setting chef service URL to: $chefServerUrl`n"
    Write-Host "Setting validation data to: `nvalidationClientName=$validationClientName `nvalidationKey=$validationKey`n"
    Add-Content c:\chef\knife.rb $knifeNodeName 
    Add-Content c:\chef\knife.rb $chefServerUrl
    Add-Content c:\chef\knife.rb $validationClientName
    Add-Content c:\chef\knife.rb $validationKey

# Now we'll go configure the chef-client with this data, also.

    Add-Content c:\chef\client.rb $chefServerUrl
    Add-Content c:\chef\client.rb $validationClientName
    Add-Content c:\chef\client.rb $fileCachePath


    # Build first-boot.json and kick off the initial chef run
    Write-Host "Adding $run_list to c:\chef\first-boot.json"  
    Add-Content c:\chef\first-boot.json $run_list
    Write-Host "Running the first chef-client run...`n"
    $cmdstring = "c:\opscode\chef\bin\chef-client -c c:\chef\client.rb -k c:\chef\client.pem -K c:\chef\" + $chefOrgValue[1] + "-validator.pem -j c:\chef\first-boot.json -L c:\chef\logs\firstrun.log -l debug"

    cmd.exe /c $cmdstring
