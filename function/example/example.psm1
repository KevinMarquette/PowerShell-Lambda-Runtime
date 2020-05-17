function Test-Lambda
{
    [cmdletbinding()]
    param(
        [parameter()]
        $InputObject,

        [parameter()]
        $Context
    )
    Write-Host "Starting new function"
    Write-Verbose "Doing some verbose work"
    Write-Warning "with some warnings"


    "Input is [$InputObject]"
    "Input has these keys [$($InputObject.Keys -join ',')]"
    "Context has these keys [$($Context.Keys -join ',')]"
    "Final Output is standard pipeline"
    "and is not limited to the last item."
    " input[$InputObject]"
}