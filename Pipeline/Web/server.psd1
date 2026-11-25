@{
    Server = @{
        Request = @{
            # Seconds before Pode answers 408. Above the 120 s connection-test limit so an MFA (Duo)
            # push has time to be approved and the test reports its own result.
            Timeout = 150
        }
    }
}
