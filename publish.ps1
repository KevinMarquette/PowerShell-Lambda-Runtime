<#
    .Notes
    This assumes you have already authenticated to your AWS Account
#>
[cmdletbinding()]
param(
    $S3Bucket = 'kemarqu-temp',
    $LambdaRole = 'lambda-role',
    [switch]$BootStrap,
    [switch]$LambdaOnly
)
$VerbosePreference = "Continue"

Push-Location $PSScriptRoot
If(-not(Test-Path './layer/powershell/pwsh'))
{
    Write-Error '[./layer/powershell/pwsh] is missing. Donload and place powershell in the [./layer/powershell] folder.' -ErrorAction Stop

}

Write-Verbose "Creating artifacts"
if($isWindows){
    bash createzips.sh | Out-Null
}else{
    createzips.sh | Out-Null
}

Write-S3Object -BucketName $S3Bucket -File .\function.zip

if(!$LambdaOnly){
    Write-S3Object -BucketName $S3Bucket -File .\layer.zip

    $LMLayerVersion = @{
        CompatibleRuntime = 'dotnetcore3.1'
        Description = 'Custom pwsh runtime'
        LayerName = 'pwsh-runtime'
        LicenseInfo = 'mit'
        Content_S3Bucket = $S3Bucket
        Content_S3Key = 'layer.zip'
        OutVariable = 'layer'
    }
    $layer = Publish-LMLayerVersion @LMLayerVersion
}
else
{
    $layer = Get-LMLayerVersionList -LayerName pwsh-runtime | Select -First 1
}
#Remove-LMFunction -FunctionName pwsh-runtime
if($BootStrap)
{
    $LMFunction = @{
        TimeOut = 10
        Code_S3Bucket = $S3Bucket
        Code_S3Key = 'function.zip'
        FunctionName = 'pwsh-runtime'
        handler = 'example.Test-Lambda'
        layer = $layer.LayerVersionArn
        Role = (Get-IAMRole $LambdaRole).Arn
        Runtime = 'provided'
    }
    Publish-LMFunction @LMFunction
}
else
{
    $null = @(
        $LMFunctionConfiguration = @{
            FunctionName = 'pwsh-runtime'
            TimeOut = 10
            handler = 'example.Test-Lambda'
            layer = $layer.LayerVersionArn
            Role = (Get-IAMRole $LambdaRole).Arn
            Runtime = 'provided'
            Environment_Variable = @{'Debug'='true'}
        }
        Update-LMFunctionConfiguration @LMFunctionConfiguration

        $LMFunctionCode = @{
            FunctionName = 'pwsh-runtime'
            S3Bucket = $S3Bucket
            S3Key = 'function.zip'
        }
        Update-LMFunctionCode @LMFunctionCode
    )
}


# Execute to validate
$Result = Invoke-LMFunction -FunctionName pwsh-runtime -Payload '{"hello":"World"}'
[System.IO.StreamReader]::new($Result.Payload).ReadToEnd()
[console]::beep(500,300)
<#

aws lambda publish-layer-version --layer-name pwsh-runtime --content S3Bucket=kemarqu-temp,S3Key=layer.zip
$LayerVersionArn  = Get-LMLayerList | where LayerName -eq pwsh-runtime | Foreach{
    $_.LatestMatchingVersion.LayerVersionArn
}
$layerArn = $layer | ConvertFrom-Json | % LayerVersionArn
aws lambda update-function-configuration --function-name pwsh-runtime --layers $layerArn
aws --% lambda invoke --function-name pwsh-runtime response.txt
#>
