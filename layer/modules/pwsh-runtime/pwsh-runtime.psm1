
function Script:Get-LambdaApiUri {
    <#
        .Notes
        Provides one of the 4 Lambda runtime interfaces
    #>
    param
    (
        [parameter(mandatory)]
        [validateset(
            'RuntimeError',
            'Next',
            'Response',
            'Error'
        )]
        [string]
        $Endpoint,

        [string]
        $RequestId = 'undefined',

        [string]
        $LambdaApi = $env:AWS_LAMBDA_RUNTIME_API
    )

    $baseUri = "http://$LambdaApi/2018-06-01/runtime"
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
    Write-Verbose 'Headers:' -Verbose
    $webRequest.headers.GetEnumerator() | Foreach-Object {
        Write-Verbose ('  {0} [{1}]:'-f $_.key, ($_.value -join ',')) -Verbose
    }
    $webRequest
}

function Get-LambdaEventData {
    param($InputObject)

    $eventData = $InputObject.content
    Write-Verbose 'Event Contents:' -Verbose
    Write-Verbose $eventData -Verbose

    if($InputObject.Headers['Content-Type'] -eq 'application/json')
    {
        #TotalyNotAHack
        # using EA Ignore so if it can't convert to json
        # it will leave the original value unchanged
        try
        {
            $eventData = $eventData | ConvertFrom-Json -AsHashtable -ErrorAction Ignore
        }
        catch
        {
            ""
        }
    }
    $eventData
}

function Publish-LambdaResponse
{
    param
    (
        $Body,

        [string]
        $RequestId
    )

    $uri = Get-LambdaApiUri -Endpoint Response -RequestID $RequestId
    $restMethod = @{
        Uri = $uri
        Method = 'Post'
    }
    if($Body){
        Write-Verbose "Posting Response [$Body]" -Verbose
        $restMethod['Body'] = $Body
    }

    Write-Verbose 'Posting Execution Success' -Verbose
    Invoke-RestMethod @restMethod
}

function Get-LambdaInvocation
{
    <#
        .DESCRIPTION
        Parses the hander to identify the function and module

        .Notes
        Hander can be any of these patterns
            Module and Function:
                [MyModule.MyFunction]
                [MyModule.psd1.MyFunction]
                [./MyModule.psm1.MyFunction]
                [./src/MyModule.psm1.MyFunction]
            Script:
                [./myscript.ps1]
    #>
    param
    (
        [string]
        $Handler = $env:_HANDLER
    )

    Write-Verbose "Handler [$Handler]" -Verbose
    switch -regex ($Handler)
    {
        $null
        {
            Write-Error 'HandlerNotDefined'
            continue
        }
        # Script only
        '.*\.ps1$'
        {
            # use of Resolve-Path to both discover and validate path
            # errors will exit to exception handler
            $function = (Resolve-Path $PSItem).Path
            continue
        }
        # MyModule.MyFunction patterns
        '^(?<module>.*(?<file>\.ps[dm]1)?)\.(?<function>.*)$'
        {
            $function = $matches.function
            $module = $matches.module

            # if its a path to a module, resolve it
            if($matches.file)
            {
                $module = (Resolve-Path $module).Path
            }
            else
            {
                # the module could be at the project root
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
        # last ditch effort to find something
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
    param(
        $Header
    )
    $context= @{}

    # Injecting all environment variables
    Get-ChildItem -Path env: | ForEach-Object {
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
    param
    (
        $InputObject,
        [string]
        $RequestId,
        $Header
    )

    Write-Verbose "Processing Error Info [$RequestId]" -Verbose
    if($RequestId)
    {
        $lambdaApiUri = @{
            Endpoint = 'Error'
            RequestID = $RequestId
        }
    }
    else
    {
        $lambdaApiUri = @{
            Endpoint = 'RuntimeError'
        }
    }

    $uri = Get-LambdaApiUri @lambdaApiUri

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
                $InputObject.ScriptStackTrace -split '\n' : $null

            stackTrace = $InputObject.Exception.StackTrace ?
                $InputObject.Exception.StackTrace -split '\n' : $null
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

    Write-Verbose 'Error Details' -Verbose
    Write-Warning ($InputObject | Format-List '*' -Force | Out-String)

    Write-Verbose 'Create Error Body' -Verbose
    $body = $lambdaError | ConvertTo-Json

    Write-Verbose "Posting error to [$uri]" -Verbose
    $body | Invoke-RestMethod -Uri $uri -Method Post -Header @{
        'Lambda-Runtime-Function-Error-Type' = $lambdaError.errorType
    }
}

function Format-Environment
{
    # Outputs environment variables, uses patten that could be used in powershell
    Write-Verbose 'Environment Variables:' -Verbose
    Get-ChildItem -Path env: | Foreach-Object {
        Write-Output ('$env:{0} = "{1}"'-f $_.name, $_.value)
    }
}

function Set-PSModulePath {
    <#
    .Notes
    Sets the module path to the equivalent of these project paths:
        ./function                 # root of project
        ./function/modules         # project modules folder
        ./layer/modules            # runtime modules folder
        ./layer/powershell/modules # build in modules
    #>
    param
    (
        [string]
        $ProjectPath,
        [string]
        $RuntimePath
    )

    Write-Verbose "Configuring PSModulePath" -Verbose
    $env:PSModulePath = @(
        $ProjectPath
        Join-Path $ProjectPath 'modules'
        Join-Path $RuntimePath 'modules'
        Join-Path $RuntimePath 'powershell' 'modules'
    ) -join ':' # linux uses : to join paths
    Write-Verbose "  [$env:PSModulePath]"
}
