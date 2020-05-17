Write-Host "PowerShell-Lambda-Runtime"
$ErrorActionPreference = "Stop"
$runtimePath = $PWD
Write-Verbose "Importing runtime helpers" -Verbose
$env:PSModulePath = Join-Path $runtimePath 'modules'
Import-Module pwsh-runtime

try
{
    Format-Environment
    Push-Location $env:LAMBDA_TASK_ROOT

    Set-PSModulePath -ProjectPath $PWD -RuntimePath $runtimePath

    $invocation = Get-LambdaInvocation -Hander $env:_HANDLER
    $module = $invocation.module
    $function = $invocation.function

    if($module)
    {
        Write-Verbose "  Importing Module [$module]" -Verbose
        Import-Module $module -Force
    }

    while($true) # intentional infinite loop
    {
        Remove-Variable eventDate,header,body,webRequest -ErrorAction Ignore
        $env:_X_AMZN_TRACE_ID = ''

        try
        {
            Write-Verbose "Checking for next invocation" -Verbose
            $webRequest = Get-LambdaNextRequest
            $header = $webRequest.Headers
            $requestId = $header["Lambda-Runtime-Aws-Request-Id"]
            $env:_X_AMZN_TRACE_ID = $header["Lambda-Runtime-Trace-Id"]

            $context = Get-LambdaContext -Header $header
            $eventData = Get-LambdaEventData -InputObject $WebRequest

            Write-Verbose "Invoking [$function]" -Verbose
            $body = & $function $eventData $context -Verbose | Out-String -width 1024

            Publish-LambdaResponse -Body $body -requestId $requestId
        }
        catch
        {
            Publish-LambdaErrorDetails -InputObject $PSItem -RequestID $requestId -Header $header
        }
    }
}
catch
{
    Publish-LambdaErrorDetails -InputObject $PSItem
    Exit 1
}
