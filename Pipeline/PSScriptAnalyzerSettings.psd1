@{
    # Style rules that don't fit an internal ops module; correctness rules stay on
    ExcludeRules = @(
        'PSUseOutputTypeCorrectly'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSReviewUnusedParameter'      # false positives for variables captured by local scriptblocks
        'PSAvoidUsingWriteHost'        # console output is intended in entry scripts and logging
        'PSAvoidUsingPositionalParameters'  # compact internal helpers (Get-GIConfigValue, New-GICheck)
    )
}
