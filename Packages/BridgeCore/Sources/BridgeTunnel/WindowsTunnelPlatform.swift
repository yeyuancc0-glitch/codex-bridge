#if canImport(WinSDK)
  public typealias TunnelHelperVerifier = WindowsTunnelHelperVerifier
  typealias TunnelDirectoryHandle = WindowsSecureRunDirectory
  typealias TunnelProcessLauncher = WindowsTunnelProcessLauncher
  typealias TunnelSpawnedProcess = WindowsTunnelSpawnedProcess
  typealias TunnelVerifiedHelper = WindowsTunnelVerifiedHelper
#endif
