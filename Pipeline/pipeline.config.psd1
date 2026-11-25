# Golden image pipeline configuration. No secrets here: credentials are SecretManagement names.
@{
  # Folders for run state, HTML reports and logs (relative = under the Pipeline folder)
  Paths      = @{ State = 'state'; Reports = 'reports'; Logs = 'logs' }

  # vCenter used for snapshots, power operations and guest operations
  vCenter    = @{ Server = 'vcsa01.domain.local'; CredentialSecret = 'GI-vCenter' }

  # Horizon Connection Server REST API
  Horizon    = @{ Server = 'hzcs01.domain.local'; CredentialSecret = 'GI-Horizon'; Domain = 'DOMAIN'; SkipCertificateCheck = $false }

  # App Volumes Manager REST API
  AppVolumes = @{ Server = 'avm01.domain.local';  CredentialSecret = 'GI-AppVol'; SkipCertificateCheck = $false
                  TestPackages = @('Notepad++')            # packages assigned to the test pool's computer OU
                  # API paths differ between App Volumes releases: confirm against your AVM's API docs
                  Endpoints = @{ Session = '/cv_api/sessions'; OnlineEntities = '/cv_api/online_entities'; Attachments = '/app_volumes/app_attachments' } }

  # The golden image VM and what runs inside it
  GoldenImage = @{
    VmName            = 'W11-GI-01'
    GuestCredentialSecret = 'GI-GuestAdmin'
    ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
    InstallerSourceDir = ''   # optional host folder synced to <script dir>\Install in the guest
    Actions           = @('VmTools','Horizon','DEM','AppVolumes','FSLogix','MsTeams')   # run with -Unattended after updates
    WindowsUpdate     = @{ Enabled = $true; MaxPasses = 5 }
    FinalizeAction    = 'Finalize'
    PowerOffTimeoutMin = 90
    ActionTimeoutMin  = 60    # minutes per package install before it's stopped and the step fails
    GuestWorkDir      = 'C:\ProgramData\VDI\Pipeline'   # pipeline-owned guest folder; deleted by CleanupGuest
    Watcher = @{ LogPollSec = 10; IdlePollSec = 60; StatusPollSec = 60; WatchingWindowSec = 30
                 StaleHeartbeatSec = 180; MaxRelaunches = 3; MaxStepAttempts = 4; FixTimeoutSec = 600 }
  }

  # Test pool receives every new snapshot; production pools only after approval
  Pools = @{
    Test       = @{ Name = 'TST-W11'; LogoffPolicy = 'FORCE_LOGOFF' }
    Production = @( @{ Name = 'PRD-W11'; LogoffPolicy = 'WAIT_FOR_LOGOFF' } )
    PushTimeoutMin = 120
  }

  # Post-push validation on the test pool
  Validation = @{
    GuestSampleCount = 2
    RequiredServices = @('wsnm','svservice','frxsvc')
    MachineReadyTimeoutMin = 60
  }

  # Snapshot naming and retention (Prune = $false => report only). Runs after production PostCheck passes.
  # Names: '<NamePrefix> yy.MM.dd.HHmm'. Mode Chain keeps: root (Master) > previous Baseline > production Baseline.
  # ProtectAncestors: Chain = keep parents of a pending push; Tree = keep parents of any in-use snapshot.
  Snapshots = @{
    NamePrefix = 'Baseline'; Mode = 'Chain'; Keep = 2; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true
    ConsolidateTimeoutMin = 60; MinFreeSpacePercent = 15
    CleanupFailedRuns = $true   # revert to / remove pre-maint snapshots of failed runs at the start of Maintain
  }

  # Production promotion behaviour
  Promotion = @{
    AutoPromote = $false
    MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' }   # next window used when no -StartTime given
    PipelineSchedule  = @{ Day = 'Tuesday'; Time = '20:00' }               # weekly start of the pipeline scheduled task
  }

  # Run report email
  Email = @{ Enabled = $false; SmtpServer = 'smtp.domain.local'; Port = 25; From = 'vdi-pipeline@domain.local'; To = @('vdi-team@domain.local'); UseSsl = $false }

  # Pode web dashboard
  Dashboard = @{ Port = 8443; CertificateThumbprint = ''; ViewerGroup = 'DOMAIN\VDI-Pipeline-Viewers'; ApproverGroup = 'DOMAIN\VDI-Pipeline-Approvers'; AdminGroup = 'DOMAIN\VDI-Pipeline-Admins'; RefreshSeconds = 20 }
}
