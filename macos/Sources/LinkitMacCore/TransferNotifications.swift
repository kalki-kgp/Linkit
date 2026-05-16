import Foundation

public extension Notification.Name {
    static let linkitTransferDidBeginUpload = Notification.Name("tech.kalkikgp.linkit.transferDidBeginUpload")
    static let linkitTransferDidFinish = Notification.Name("tech.kalkikgp.linkit.transferDidFinish")
}

public enum LinkitTransferNotification {
    public static let transferIdKey = "transferId"
    public static let filenameKey = "filename"
    public static let statusKey = "status"
    public static let errorKey = "error"
}
