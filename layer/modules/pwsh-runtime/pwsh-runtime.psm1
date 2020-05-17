
function Script:Get-LambdaApiUri {
    param(
        [validateset('RuntimeError','Next','Response','Error')]
        $Endpoint,
        $RequestId = 'undefined',
        $lambdaApi = $env:AWS_LAMBDA_RUNTIME_API
    )
    $baseUri = "http://$lambdaApi/2018-06-01/runtime"
    $uri = @{
        RuntimeError = "$baseUri/init/error"
        Next = "$baseUri/invocation/next"
        Response = "$baseUri/invocation/{0}/response" -f $RequestId
        Error = "$baseUri/invocation/{0}/error" -f $RequestId
    }
    return $uri[$Endpoint]
}

function Get-LambdaNextRequest
{
    $uri = Get-LambdaApiUri -Endpoint Next
    $webRequest = Invoke-WebRequest -Uri $uri -Method Get -Verbose
    Write-Verbose "Headers:" -Verbose
    $webRequest.headers.GetEnumerator() | Foreach-Object {
        Write-Verbose ("  {0} [{1}]:"-f $_.key, ($_.value -join ',')) -Verbose
    }
    $webRequest
}

function Get-LambdaEventData {
    param($InputObject)

    $eventData = $InputObject.content
    Write-Verbose "Event Contents:" -Verbose
    Write-Verbose $eventData -Verbose

    if($InputObject.Headers['Content-Type'] -eq 'application/json')
    {
        # using EA Ignore so if it can't convert to json it leaves the original value unchanged
        $eventData = $eventData | ConvertFrom-Json -AsHashtable -ErrorAction Ignore
    }
    $eventData
}

function Publish-LambdaResponse
{
    param($Body,$RequestId)

    $uri = Get-LambdaApiUri -Endpoint Response -RequestID $requestId
    $restMethod = @{
        Uri = $uri
        Method = 'Post'
    }
    if($body){
        Write-Verbose "Posting Response @[$body]@" -Verbose
        $restMethod['Body'] = $body
    }

    Write-Verbose "Posting Execution Success" -Verbose
    Invoke-RestMethod @restMethod
}

function Get-LambdaInvocation
{
    param($handler = $env:_HANDLER)
    Write-Verbose "Handler [$handler]" -Verbose
    switch -regex ($handler)
    {
        $null
        {
            Write-Error "HandlerNotDefined"
        }
        '.*\.ps1$'
        {
            # using resolve path to both discover and validate path
            $function = (Resolve-Path $PSItem).Path
            continue
        }
        '^(?<module>.*(?<file>\.ps[dm]1)?)\.(?<function>.*)$'
        {
            $function = $matches.function
            $module = $matches.module

            # if its a path to a module, resolve it
            if($matches.file){
                $module = (Resolve-Path $module).Path
            }
            else
            {
                if(Test-Path "$module.psd1")
                {
                    $module = (Resolve-Path "$module.psd1").Path
                }
                elseif(Test-Path "$module.psm1")
                {
                    $module = (Resolve-Path "$module.psm1").Path
                }
            }
            continue
        }
        default
        {
            $function = (Resolve-Path "$PSItem.ps1").Path
        }
    }
    Write-Verbose "  Using Invocation [$function]" -Verbose
    return [pscustomobject]@{
        function = $function
        module = $module
    }
}

function Get-LambdaContext
{
    param($Header)
    $context= @{}
    Get-ChildItem env: | Foreach {
        $context[$_.name] = $_.value
    }
    if($Header)
    {
        $Header.GetEnumerator() | Foreach-Object {
            $context[$_.key] = $_.value
        }
    }
    $context
}

function Publish-LambdaErrorDetails
{
    param($InputObject,$RequestId,$Header)
    Write-Verbose "Processing Error Info [$RequestId]" -Verbose
    if($RequestId)
    {
        $uri = Get-LambdaApiUri -Endpoint Error -RequestID $RequestId
    }
    else
    {
        $uri = Get-LambdaApiUri -Endpoint RuntimeError
    }

    $lambdaError = [ordered]@{
        errorType = $InputObject.Exception.GetType().Name
        errorMessage = $InputObject.ToString()
    }
    if($env:Debug -eq 'true')
    {
        $lambdaError.errorRecord = @{
            targetObject = $InputObject.TargetObject
            fullyQualifiedErrorId = $InputObject.FullyQualifiedErrorId
            errorDetails = $InputObject.ErrorDetails
            source = $InputObject.Exception.Source
            targetSite = $InputObject.Exception.TargetSite  | Out-String

            scriptStackTrace = $InputObject.ScriptStackTrace ?
                $InputObject.ScriptStackTrace -split "\n" : $null

            stackTrace = $InputObject.Exception.StackTrace ?
                $InputObject.Exception.StackTrace -split "\n" : $null
        }
        $lambdaError.context = Get-LambdaContext -Header $Header
    }
    else
    {
        $lambdaError.context = @{
            'AWS_LAMBDA_LOG_STREAM_NAME' = $env:AWS_LAMBDA_LOG_STREAM_NAME
            'AWS_LAMBDA_LOG_GROUP_NAME' = $env:AWS_LAMBDA_LOG_GROUP_NAME
            'Lambda-Runtime-Aws-Request-Id' = $Header['Lambda-Runtime-Aws-Request-Id']
            'Debug' = 'false'
            'Debug_Message' = 'Set Debug="true" as an environment variable for all environment variables, headers, and errorrecord details.'
        }
    }
    Write-Verbose "Dispaying details" -Verbose
    Write-Warning ($InputObject | Format-List '*' -Force | Out-String)
    Write-Verbose "Create body" -Verbose
    $body = $lambdaError | ConvertTo-Json
    Write-Verbose "Posting error to [$uri]"
    $body | Invoke-RestMethod -Uri $uri -Method Post -Header @{
        'Lambda-Runtime-Function-Error-Type' = $lambdaError.errorType
    }
}

function Format-Environment
{
    Write-Verbose "Environment Variables:" -Verbose
    Get-ChildItem env: | Foreach {
        Write-Output ('$env:{0} = "{1}"'-f $_.name, $_.value)
    }
}

function Set-PSModulePath {
    param($ProjectPath,$RuntimePath)
    Write-Verbose "Configuring PSModulePath" -Verbose
    $env:PSModulePath = @(
        $ProjectPath
        Join-Path $ProjectPath 'modules'
        Join-Path $RuntimePath 'modules'
        Join-Path $RuntimePath 'powershell' 'modules'
    ) -join ':'
    Write-Verbose "  [$env:PSModulePath]"
}