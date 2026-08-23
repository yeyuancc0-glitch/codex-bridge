import Foundation

enum ServiceStorePrivateBackup {
  enum Preparation: Equatable {
    case existing
    case newFileReady
  }
}
