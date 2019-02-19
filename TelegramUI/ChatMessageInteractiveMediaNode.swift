import Foundation
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import Display
import TelegramCore

private struct FetchControls {
    let fetch: (Bool) -> Void
    let cancel: () -> Void
}

enum InteractiveMediaNodeSizeCalculation {
    case constrained(CGSize)
    case unconstrained
}

enum InteractiveMediaNodeContentMode {
    case aspectFit
    case aspectFill
}

enum InteractiveMediaNodeActivateContent {
    case `default`
    case stream
    case automaticPlayback
}

enum InteractiveMediaNodeAutodownloadMode {
    case none
    case prefetch
    case full
}

final class ChatMessageInteractiveMediaNode: ASDisplayNode {
    private let imageNode: TransformImageNode
    private var currentImageArguments: TransformImageArguments?
    private var videoNode: UniversalVideoNode?
    private var statusNode: RadialStatusNode?
    var videoNodeDecoration: ChatBubbleVideoDecoration?
    private var badgeNode: ChatMessageInteractiveMediaBadge?
    private var tapRecognizer: UITapGestureRecognizer?
    
    private var context: AccountContext?
    private var message: Message?
    private var media: Media?
    private var themeAndStrings: (PresentationTheme, PresentationStrings)?
    private var sizeCalculation: InteractiveMediaNodeSizeCalculation?
    private var wideLayout: Bool?
    private var automaticDownload: InteractiveMediaNodeAutodownloadMode?
    var automaticPlayback: Bool?
    
    private let statusDisposable = MetaDisposable()
    private let fetchControls = Atomic<FetchControls?>(value: nil)
    private var fetchStatus: MediaResourceStatus?
    private var actualFetchStatus: MediaResourceStatus?
    private let fetchDisposable = MetaDisposable()
    
    private let videoNodeReadyDisposable = MetaDisposable()
    private let playerStatusDisposable = MetaDisposable()
    
    private var updateTimer: SwiftSignalKit.Timer?
    private var playerStatus: MediaPlayerStatus? {
        didSet {
            if self.playerStatus != oldValue {
                if let playerStatus = playerStatus, case .playing = playerStatus.status {
                    self.ensureHasTimer()
                } else {
                    self.stopTimer()
                }
                self.updateFetchStatus()
            }
        }
    }
    
    private var secretTimer: SwiftSignalKit.Timer?
    
    var visibilityPromise = ValuePromise<ListViewItemNodeVisibility>(.none)
    var visibility: ListViewItemNodeVisibility = .none {
        didSet {
            if let videoNode = self.videoNode {
                switch self.visibility {
                    case .visible:
                        if !videoNode.canAttachContent {
                            videoNode.canAttachContent = true
                            if videoNode.hasAttachedContext {
                                videoNode.play()
                            }
                        }
                    case .none:
                        videoNode.canAttachContent = false
                }
            }
            self.visibilityPromise.set(self.visibility)
        }
    }
    
    var activateLocalContent: (InteractiveMediaNodeActivateContent) -> Void = { _ in }
    
    override init() {
        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = [.subsequentUpdates]
        
        super.init()
        
        self.imageNode.displaysAsynchronously = false
        self.addSubnode(self.imageNode)
    }
    
    deinit {
        self.statusDisposable.dispose()
        self.videoNodeReadyDisposable.dispose()
        self.playerStatusDisposable.dispose()
        self.fetchDisposable.dispose()
        self.secretTimer?.invalidate()
    }
    
    override func didLoad() {
        super.didLoad()
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.imageTap(_:)))
        self.imageNode.view.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer
    }
    
    private func progressPressed(canActivate: Bool) {
        if let fetchStatus = self.fetchStatus {
            var isAnimated = false
            if let file = self.media as? TelegramMediaFile, file.isAnimated {
                isAnimated = true
            }
            
            var activateContent = false
            if let state = self.statusNode?.state, case .play = state {
                activateContent = true
            } else if let message = self.message, !message.flags.isSending && (self.automaticPlayback ?? false) && !isAnimated {
                activateContent = true
            }
            if canActivate, activateContent {
                switch fetchStatus {
                    case .Remote, .Fetching:
                        self.activateLocalContent(.stream)
                    default:
                        break
                }
                return
            }
            
            switch fetchStatus {
                case .Fetching:
                    if let context = self.context, let message = self.message, message.flags.isSending {
                       let _ = context.account.postbox.transaction({ transaction -> Void in
                            deleteMessages(transaction: transaction, mediaBox: context.account.postbox.mediaBox, ids: [message.id])
                        }).start()
                    } else if let media = media, let context = self.context, let message = message {
                        if let media = media as? TelegramMediaFile {
                            messageMediaFileCancelInteractiveFetch(context: context, messageId: message.id, file: media)
                        } else if let media = media as? TelegramMediaImage, let resource = largestImageRepresentation(media.representations)?.resource {
                            messageMediaImageCancelInteractiveFetch(context: context, messageId: message.id, image: media, resource: resource)
                        }
                    }
                    if let cancel = self.fetchControls.with({ return $0?.cancel }) {
                        cancel()
                    }
                case .Remote:
                    if let fetch = self.fetchControls.with({ return $0?.fetch }) {
                        fetch(true)
                    }
                case .Local:
                    break
            }
        }
    }
    
    @objc func imageTap(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            let point = recognizer.location(in: self.imageNode.view)
            if let fetchStatus = self.fetchStatus, case .Local = fetchStatus {
                self.activateLocalContent((self.automaticPlayback ?? false) ? .automaticPlayback : .default)
            } else {
                if let message = self.message, message.flags.isSending {
                    if let statusNode = self.statusNode, statusNode.frame.contains(point) {
                        self.progressPressed(canActivate: true)
                    }
                } else {
                    self.progressPressed(canActivate: true)
                }
            }
        }
    }
    
    func asyncLayout() -> (_ context: AccountContext, _ theme: PresentationTheme, _ strings: PresentationStrings, _ message: Message, _ media: Media, _ automaticDownload: InteractiveMediaNodeAutodownloadMode, _ peerType: MediaAutoDownloadPeerType, _ sizeCalculation: InteractiveMediaNodeSizeCalculation, _ layoutConstants: ChatMessageItemLayoutConstants, _ contentMode: InteractiveMediaNodeContentMode) -> (CGSize, CGFloat, (CGSize, Bool, Bool, ImageCorners) -> (CGFloat, (CGFloat) -> (CGSize, (ContainedViewLayoutTransition, Bool) -> Void))) {
        let currentMessage = self.message
        let currentMedia = self.media
        let imageLayout = self.imageNode.asyncLayout()
        
        let currentVideoNode = self.videoNode
        let hasCurrentVideoNode = currentVideoNode != nil
        let currentAutomaticDownload = self.automaticDownload
        let currentAutomaticPlayback = self.automaticPlayback
        
        return { [weak self] context, theme, strings, message, media, automaticDownload, peerType, sizeCalculation, layoutConstants, contentMode in
            var nativeSize: CGSize
            
            let isSecretMedia = message.containsSecretMedia
            var secretBeginTimeAndTimeout: (Double, Double)?
            if isSecretMedia {
                for attribute in message.attributes {
                    if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
                        if let countdownBeginTime = attribute.countdownBeginTime {
                            secretBeginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                        }
                        break
                    }
                }
            }
            
            var storeToDownloadsPeerType: MediaAutoDownloadPeerType?
            for media in message.media {
                if media is TelegramMediaImage {
                    storeToDownloadsPeerType = peerType
                }
            }
            
            var isInlinePlayableVideo = false
            var maxDimensions = layoutConstants.image.maxDimensions
            
            var unboundSize: CGSize
            if let image = media as? TelegramMediaImage, let dimensions = largestImageRepresentation(image.representations)?.dimensions {
                unboundSize = CGSize(width: floor(dimensions.width * 0.5), height: floor(dimensions.height * 0.5))
            } else if let file = media as? TelegramMediaFile, var dimensions = file.dimensions {
                if let thumbnail = file.previewRepresentations.first {
                    let dimensionsVertical = dimensions.width < dimensions.height
                    let thumbnailVertical = thumbnail.dimensions.width < thumbnail.dimensions.height
                    if dimensionsVertical != thumbnailVertical {
                        dimensions = CGSize(width: dimensions.height, height: dimensions.width)
                    }
                }
                unboundSize = CGSize(width: floor(dimensions.width * 0.5), height: floor(dimensions.height * 0.5))
                if file.isAnimated {
                    unboundSize = unboundSize.aspectFilled(CGSize(width: 480.0, height: 480.0))
                } else if file.isVideo && !file.isAnimated, case let .constrained(constrainedSize) = sizeCalculation {
                    if unboundSize.width > unboundSize.height {
                        maxDimensions = CGSize(width: constrainedSize.width, height: layoutConstants.video.maxHorizontalHeight)
                    } else {
                        maxDimensions = CGSize(width: constrainedSize.width, height: layoutConstants.video.maxVerticalHeight)
                    }
                } else if file.isSticker {
                    unboundSize = unboundSize.aspectFilled(CGSize(width: 162.0, height: 162.0))
                }
                isInlinePlayableVideo = file.isVideo && !isSecretMedia
            } else if let image = media as? TelegramMediaWebFile, let dimensions = image.dimensions {
                unboundSize = CGSize(width: floor(dimensions.width * 0.5), height: floor(dimensions.height * 0.5))
            } else if let wallpaper = media as? WallpaperPreviewMedia {
                switch wallpaper.content {
                    case let .file(file, _):
                        if let thumbnail = file.previewRepresentations.first, var dimensions = file.dimensions {
                            let dimensionsVertical = dimensions.width < dimensions.height
                            let thumbnailVertical = thumbnail.dimensions.width < thumbnail.dimensions.height
                            if dimensionsVertical != thumbnailVertical {
                                dimensions = CGSize(width: dimensions.height, height: dimensions.width)
                            }
                            unboundSize = CGSize(width: floor(dimensions.width * 0.5), height: floor(dimensions.height * 0.5)).fitted(CGSize(width: 240.0, height: 240.0))
                        } else {
                            unboundSize = CGSize(width: 54.0, height: 54.0)
                        }
                    case .color:
                        unboundSize = CGSize(width: 128.0, height: 128.0)
                }
            } else {
                unboundSize = CGSize(width: 54.0, height: 54.0)
            }
            
            switch sizeCalculation {
                case let .constrained(constrainedSize):
                    if unboundSize.width > unboundSize.height {
                        nativeSize = unboundSize.aspectFitted(constrainedSize)
                    } else {
                        nativeSize = unboundSize.aspectFitted(CGSize(width: constrainedSize.height, height: constrainedSize.width))
                    }
                case .unconstrained:
                    nativeSize = unboundSize
            }
            
            let maxWidth: CGFloat
            if isSecretMedia {
                maxWidth = 180.0
            } else {
                maxWidth = maxDimensions.width
            }
            if isSecretMedia {
                let _ = PresentationResourcesChat.chatBubbleSecretMediaIcon(theme)
            }
            
            return (nativeSize, maxWidth, { constrainedSize, automaticPlayback, wideLayout, corners in
                var resultWidth: CGFloat
                
                isInlinePlayableVideo = isInlinePlayableVideo && automaticPlayback
                
                switch sizeCalculation {
                    case .constrained:
                        if isSecretMedia {
                            resultWidth = maxWidth
                        } else {
                            let maxFittedSize = nativeSize.aspectFitted(maxDimensions)
                            resultWidth = min(nativeSize.width, min(maxFittedSize.width, min(constrainedSize.width, maxDimensions.width)))
                            resultWidth = max(resultWidth, layoutConstants.image.minDimensions.width)
                        }
                    case .unconstrained:
                        resultWidth = constrainedSize.width
                }
                
                return (resultWidth, { boundingWidth in
                    var boundingSize: CGSize
                    let drawingSize: CGSize
                    
                    switch sizeCalculation {
                        case .constrained:
                            if isSecretMedia {
                                boundingSize = CGSize(width: maxWidth, height: maxWidth)
                                drawingSize = nativeSize.aspectFilled(boundingSize)
                            } else {
                                let fittedSize = nativeSize.fittedToWidthOrSmaller(boundingWidth)
                                boundingSize = CGSize(width: boundingWidth, height: fittedSize.height).cropped(CGSize(width: CGFloat.greatestFiniteMagnitude, height: layoutConstants.image.maxDimensions.height))
                                boundingSize.height = max(boundingSize.height, layoutConstants.image.minDimensions.height)
                                boundingSize.width = max(boundingSize.width, layoutConstants.image.minDimensions.width)
                                switch contentMode {
                                    case .aspectFit:
                                        drawingSize = nativeSize.aspectFittedWithOverflow(boundingSize, leeway: 4.0)
                                    case .aspectFill:
                                        drawingSize = nativeSize.aspectFilled(boundingSize)
                                }
                            }
                        case .unconstrained:
                            boundingSize = constrainedSize
                            drawingSize = nativeSize.aspectFilled(boundingSize)
                    }
                    
                    var updateImageSignal: ((Bool) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError>)?
                    var updatedStatusSignal: Signal<(MediaResourceStatus, MediaResourceStatus?), NoError>?
                    var updatedFetchControls: FetchControls?
                    
                    var mediaUpdated = false
                    if let currentMedia = currentMedia {
                        mediaUpdated = !media.isSemanticallyEqual(to: currentMedia)
                    } else {
                        mediaUpdated = true
                    }
                    
                    var isSendingUpdated = false
                    if let currentMessage = currentMessage {
                        isSendingUpdated = message.flags.isSending != currentMessage.flags.isSending
                    }
                    
                    var automaticPlaybackUpdated = false
                    if let currentAutomaticPlayback = currentAutomaticPlayback {
                        automaticPlaybackUpdated = automaticPlayback != currentAutomaticPlayback
                    }
                    
                    var statusUpdated = mediaUpdated
                    if currentMessage?.id != message.id || currentMessage?.flags != message.flags {
                        statusUpdated = true
                    }
                    
                    var replaceVideoNode: Bool?
                    var updateVideoFile: TelegramMediaFile?
                    var onlyFullSizeVideoThumbnail: Bool?
                    
                    var emptyColor: UIColor = message.effectivelyIncoming(context.account.peerId) ? theme.chat.bubble.incomingMediaPlaceholderColor : theme.chat.bubble.outgoingMediaPlaceholderColor
                    if let wallpaper = media as? WallpaperPreviewMedia, case let .file(_, patternColor) = wallpaper.content {
                        emptyColor = patternColor ?? UIColor(rgb: 0xd6e2ee, alpha: 0.5)
                    }
                    
                    if mediaUpdated || isSendingUpdated || automaticPlaybackUpdated {
                        if let image = media as? TelegramMediaImage {
                            if hasCurrentVideoNode {
                                replaceVideoNode = true
                            }
                            if isSecretMedia {
                                updateImageSignal = { synchronousLoad in
                                    return chatSecretPhoto(account: context.account, photoReference: .message(message: MessageReference(message), media: image))
                                }
                            } else {
                                updateImageSignal = { synchronousLoad in
                                    return chatMessagePhoto(postbox: context.account.postbox, photoReference: .message(message: MessageReference(message), media: image), synchronousLoad: synchronousLoad)
                                }
                            }
                            
                            updatedFetchControls = FetchControls(fetch: { manual in
                                if let strongSelf = self {
                                    if !manual {
                                        strongSelf.fetchDisposable.set(chatMessagePhotoInteractiveFetched(context: context, photoReference: .message(message: MessageReference(message), media: image), storeToDownloadsPeerType: storeToDownloadsPeerType).start())
                                    } else if let resource = largestRepresentationForPhoto(image)?.resource {
                                        strongSelf.fetchDisposable.set(messageMediaImageInteractiveFetched(context: context, message: message, image: image, resource: resource, storeToDownloadsPeerType: storeToDownloadsPeerType).start())
                                    }
                                }
                            }, cancel: {
                                chatMessagePhotoCancelInteractiveFetch(account: context.account, photoReference: .message(message: MessageReference(message), media: image))
                                if let resource = largestRepresentationForPhoto(image)?.resource {
                                    messageMediaImageCancelInteractiveFetch(context: context, messageId: message.id, image: image, resource: resource)
                                }
                            })
                        } else if let image = media as? TelegramMediaWebFile {
                            if hasCurrentVideoNode {
                                replaceVideoNode = true
                            }
                            updateImageSignal = { synchronousLoad in
                                return chatWebFileImage(account: context.account, file: image)
                            }
                            
                            updatedFetchControls = FetchControls(fetch: { _ in
                                if let strongSelf = self {
                                    strongSelf.fetchDisposable.set(chatMessageWebFileInteractiveFetched(account: context.account, image: image).start())
                                }
                            }, cancel: {
                                chatMessageWebFileCancelInteractiveFetch(account: context.account, image: image)
                            })
                        } else if let file = media as? TelegramMediaFile {
                            if isSecretMedia {
                                updateImageSignal = { synchronousLoad in
                                    return chatSecretMessageVideo(account: context.account, videoReference: .message(message: MessageReference(message), media: file))
                                }
                            } else {
                                if file.isSticker {
                                    updateImageSignal = { synchronousLoad in
                                        return chatMessageSticker(account: context.account, file: file, small: false)
                                    }
                                } else {
                                    onlyFullSizeVideoThumbnail = isSendingUpdated
                                    updateImageSignal = { synchronousLoad in
                                        return mediaGridMessageVideo(postbox: context.account.postbox, videoReference: .message(message: MessageReference(message), media: file), onlyFullSize: currentMedia?.id?.namespace == Namespaces.Media.LocalFile, autoFetchFullSizeThumbnail: true)
                                    }
                                }
                            }
                            
                            var uploading = false
                            if file.resource is VideoLibraryMediaResource {
                                uploading = true
                            }
                            
                            if file.isVideo && !isSecretMedia && automaticPlayback && !uploading {
                                updateVideoFile = file
                                if hasCurrentVideoNode {
                                    if let currentFile = currentMedia as? TelegramMediaFile, currentFile.resource is EmptyMediaResource {
                                        replaceVideoNode = true
                                    }
                                } else {
                                    replaceVideoNode = true
                                }
                            } else {
                                if hasCurrentVideoNode {
                                    replaceVideoNode = false
                                }
                            }
                            
                            updatedFetchControls = FetchControls(fetch: { manual in
                                if let strongSelf = self {
                                    if file.isAnimated {
                                        strongSelf.fetchDisposable.set(fetchedMediaResource(postbox: context.account.postbox, reference: AnyMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), statsCategory: statsCategoryForFileWithAttributes(file.attributes)).start())
                                    } else {
                                        strongSelf.fetchDisposable.set(messageMediaFileInteractiveFetched(context: context, message: message, file: file, userInitiated: manual).start())
                                    }
                                }
                            }, cancel: {
                                if file.isAnimated {
                                    context.account.postbox.mediaBox.cancelInteractiveResourceFetch(file.resource)
                                } else {
                                    messageMediaFileCancelInteractiveFetch(context: context, messageId: message.id, file: file)
                                }
                            })
                        } else if let wallpaper = media as? WallpaperPreviewMedia {
                            updateImageSignal = { synchronousLoad in
                                switch wallpaper.content {
                                    case let .file(file, _):
                                        let representations: [ImageRepresentationWithReference] = file.previewRepresentations.map({ ImageRepresentationWithReference(representation: $0, reference: AnyMediaReference.message(message: MessageReference(message), media: file).resourceReference($0.resource)) })
                                        if file.mimeType == "image/png" {
                                            return patternWallpaperImage(account: context.account, representations: representations, mode: .thumbnail)
                                        } else {
                                            return wallpaperImage(account: context.account, accountManager: context.sharedContext.accountManager, fileReference: FileMediaReference.message(message: MessageReference(message), media: file), representations: representations, alwaysShowThumbnailFirst: false, thumbnail: true, autoFetchFullSize: true)
                                        }
                                    case let .color(color):
                                        return solidColor(color)
                                }
                            }
                            
                            if case let .file(file, _) = wallpaper.content {
                                updatedFetchControls = FetchControls(fetch: { manual in
                                    if let strongSelf = self {
                                        strongSelf.fetchDisposable.set(messageMediaFileInteractiveFetched(context: context, message: message, file: file, userInitiated: manual).start())
                                    }
                                }, cancel: {
                                    messageMediaFileCancelInteractiveFetch(context: context, messageId: message.id, file: file)
                                })
                            } else {
                                boundingSize = CGSize(width: boundingSize.width, height: boundingSize.width)
                            }
                        }
                    }
                    
                    if statusUpdated {
                        if let image = media as? TelegramMediaImage {
                            if message.flags.isSending {
                                updatedStatusSignal = combineLatest(chatMessagePhotoStatus(context: context, messageId: message.id, photoReference: .message(message: MessageReference(message), media: image)), context.account.pendingMessageManager.pendingMessageStatus(message.id))
                                |> map { resourceStatus, pendingStatus -> (MediaResourceStatus, MediaResourceStatus?) in
                                    if let pendingStatus = pendingStatus {
                                        let adjustedProgress = max(pendingStatus.progress, 0.027)
                                        return (.Fetching(isActive: pendingStatus.isRunning, progress: adjustedProgress), resourceStatus)
                                    } else {
                                        return (resourceStatus, nil)
                                    }
                                }
                            } else {
                                updatedStatusSignal = chatMessagePhotoStatus(context: context, messageId: message.id, photoReference: .message(message: MessageReference(message), media: image))
                                |> map { resourceStatus -> (MediaResourceStatus, MediaResourceStatus?) in
                                    return (resourceStatus, nil)
                                }
                            }
                        } else if let file = media as? TelegramMediaFile {
                            updatedStatusSignal = combineLatest(messageMediaFileStatus(context: context, messageId: message.id, file: file), context.account.pendingMessageManager.pendingMessageStatus(message.id))
                                |> map { resourceStatus, pendingStatus -> (MediaResourceStatus, MediaResourceStatus?) in
                                    if let pendingStatus = pendingStatus {
                                        let adjustedProgress = max(pendingStatus.progress, 0.027)
                                        return (.Fetching(isActive: pendingStatus.isRunning, progress: adjustedProgress), resourceStatus)
                                    } else {
                                        return (resourceStatus, nil)
                                    }
                            }
                        } else if let wallpaper = media as? WallpaperPreviewMedia {
                            switch wallpaper.content {
                                case let .file(file, _):
                                    updatedStatusSignal = messageMediaFileStatus(context: context, messageId: message.id, file: file)
                                    |> map { resourceStatus -> (MediaResourceStatus, MediaResourceStatus?) in
                                        return (resourceStatus, nil)
                                    }
                                case .color:
                                    updatedStatusSignal = .single((.Local, nil))
                            }
                        }
                    }
                    
                    let arguments = TransformImageArguments(corners: corners, imageSize: drawingSize, boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets(), resizeMode: isInlinePlayableVideo ? .fill(.black) : .blurBackground, emptyColor: emptyColor)
                    
                    let imageFrame = CGRect(origin: CGPoint(x: -arguments.insets.left, y: -arguments.insets.top), size: arguments.drawingSize)
                    
                    let imageApply = imageLayout(arguments)
                    
                    return (boundingSize, { transition, synchronousLoads in
                        if let strongSelf = self {
                            strongSelf.context = context
                            strongSelf.message = message
                            strongSelf.media = media
                            strongSelf.wideLayout = wideLayout
                            strongSelf.themeAndStrings = (theme, strings)
                            strongSelf.sizeCalculation = sizeCalculation
                            strongSelf.automaticPlayback = automaticPlayback
                            strongSelf.automaticDownload = automaticDownload
                            
                            if let previousArguments = strongSelf.currentImageArguments {
                                if previousArguments.imageSize == arguments.imageSize {
                                    strongSelf.imageNode.frame = imageFrame
                                } else {
                                    transition.updateFrame(node: strongSelf.imageNode, frame: imageFrame)
                                }
                            } else {
                                strongSelf.imageNode.frame = imageFrame
                            }
                            strongSelf.currentImageArguments = arguments
                            imageApply()
                            
                            if let statusNode = strongSelf.statusNode {
                                var statusFrame = statusNode.frame
                                statusFrame.origin.x = floor(imageFrame.midX - statusFrame.width / 2.0)
                                statusFrame.origin.y = floor(imageFrame.midY - statusFrame.height / 2.0)
                                statusNode.frame = statusFrame
                            }
                            
                            var updatedVideoNodeReadySignal: Signal<Void, NoError>?
                            var updatedPlayerStatusSignal: Signal<MediaPlayerStatus?, NoError>?
                            if let currentReplaceVideoNode = replaceVideoNode {
                                replaceVideoNode = nil
                                if let videoNode = strongSelf.videoNode {
                                    videoNode.canAttachContent = false
                                    videoNode.removeFromSupernode()
                                    strongSelf.videoNode = nil
                                }
                                
                                if currentReplaceVideoNode, let updatedVideoFile = updateVideoFile {
                                    let decoration = ChatBubbleVideoDecoration(corners: arguments.corners, nativeSize: nativeSize, contentMode: contentMode, backgroundColor: arguments.emptyColor ?? .black)
                                    strongSelf.videoNodeDecoration = decoration
                                    let mediaManager = context.sharedContext.mediaManager
                                    
                                    let streamVideo = !updatedVideoFile.isAnimated && isMediaStreamable(message: message, media: updatedVideoFile)
                                    let videoNode = UniversalVideoNode(postbox: context.account.postbox, audioSession: mediaManager.audioSession, manager: mediaManager.universalVideoManager, decoration: decoration, content: NativeVideoContent(id: .message(message.id, message.stableId, updatedVideoFile.fileId), fileReference: .message(message: MessageReference(message), media: updatedVideoFile), streamVideo: streamVideo, enableSound: false, fetchAutomatically: false, onlyFullSizeThumbnail: (onlyFullSizeVideoThumbnail ?? false), continuePlayingWithoutSoundOnLostAudioSession: isInlinePlayableVideo, placeholderColor: emptyColor), priority: .embedded)
                                    videoNode.isUserInteractionEnabled = false
                                    
                                    strongSelf.videoNode = videoNode
                                    
                                    updatedVideoNodeReadySignal = videoNode.ready
                                    updatedPlayerStatusSignal = videoNode.status
                                    |> mapToSignal { status -> Signal<MediaPlayerStatus?, NoError> in
                                        if let status = status, case .buffering = status.status {
                                            return .single(status) |> delay(0.5, queue: Queue.mainQueue())
                                        } else {
                                            return .single(status)
                                        }
                                    }
                                }
                            }
                            
                            if let videoNode = strongSelf.videoNode {
                                if !(replaceVideoNode ?? false), let decoration = videoNode.decoration as? ChatBubbleVideoDecoration, decoration.corners != corners {
                                    decoration.updateCorners(corners)
                                }
                                
                                videoNode.updateLayout(size: arguments.drawingSize, transition: .immediate)
                                videoNode.frame = imageFrame
                                
                                if case .visible = strongSelf.visibility {
                                    if !videoNode.canAttachContent {
                                        videoNode.canAttachContent = true
                                        if videoNode.hasAttachedContext {
                                            videoNode.play()
                                        }
                                    }
                                } else {
                                    videoNode.canAttachContent = false
                                }
                            }
                            
                            if let updateImageSignal = updateImageSignal {
                                strongSelf.imageNode.setSignal(updateImageSignal(synchronousLoads), attemptSynchronously: synchronousLoads)
                            }
                            
                            if let _ = secretBeginTimeAndTimeout {
                                if updatedStatusSignal == nil, let fetchStatus = strongSelf.fetchStatus, case .Local = fetchStatus {
                                    if let statusNode = strongSelf.statusNode, case .secretTimeout = statusNode.state {   
                                    } else {
                                        updatedStatusSignal = .single((fetchStatus, nil))
                                    }
                                }
                            }
                            
                            if let updatedStatusSignal = updatedStatusSignal {
                                strongSelf.statusDisposable.set((updatedStatusSignal |> deliverOnMainQueue).start(next: { [weak strongSelf] status, actualFetchStatus in
                                    displayLinkDispatcher.dispatch {
                                        if let strongSelf = strongSelf {
                                            strongSelf.fetchStatus = status
                                            strongSelf.actualFetchStatus = actualFetchStatus
                                            strongSelf.updateFetchStatus()
                                        }
                                    }
                                }))
                            }
                            
                            if let updatedVideoNodeReadySignal = updatedVideoNodeReadySignal {
                                strongSelf.videoNodeReadyDisposable.set((updatedVideoNodeReadySignal |> deliverOnMainQueue).start(next: { [weak strongSelf] status in
                                    displayLinkDispatcher.dispatch {
                                        if let strongSelf = strongSelf, let videoNode = strongSelf.videoNode {
                                            strongSelf.insertSubnode(videoNode, aboveSubnode: strongSelf.imageNode)
                                        }
                                    }
                                }))
                            }
                            
                            if let updatedPlayerStatusSignal = updatedPlayerStatusSignal {
                                strongSelf.playerStatusDisposable.set((updatedPlayerStatusSignal |> deliverOnMainQueue).start(next: { [weak strongSelf] status in
                                    displayLinkDispatcher.dispatch {
                                        if let strongSelf = strongSelf {
                                            strongSelf.playerStatus = status
                                        }
                                    }
                                }))
                            }
                            
                            if let updatedFetchControls = updatedFetchControls {
                                let _ = strongSelf.fetchControls.swap(updatedFetchControls)
                                if case .full = automaticDownload {
                                    if let _ = media as? TelegramMediaImage {
                                        updatedFetchControls.fetch(false)
                                    } else if let image = media as? TelegramMediaWebFile {
                                        strongSelf.fetchDisposable.set(chatMessageWebFileInteractiveFetched(account: context.account, image: image).start())
                                    } else if let file = media as? TelegramMediaFile {
                                        if automaticPlayback || !file.isAnimated {
                                            let fetchSignal = messageMediaFileInteractiveFetched(context: context, message: message, file: file, userInitiated: false)
                                            if !file.isAnimated {
                                                let visibilityAwareFetchSignal = strongSelf.visibilityPromise.get()
                                                    |> mapToSignal { visibility -> Signal<Void, NoError> in
                                                        switch visibility {
                                                            case .visible:
                                                                return fetchSignal
                                                                |> mapToSignal { _ -> Signal<Void, NoError> in
                                                                    return .complete()
                                                                }
                                                            case .none:
                                                                return .complete()
                                                        }
                                                }
                                                strongSelf.fetchDisposable.set(visibilityAwareFetchSignal.start())
                                            } else {
                                                strongSelf.fetchDisposable.set(fetchSignal.start())
                                            }
                                        }
                                    }
                                } else if case .prefetch = automaticDownload, message.id.namespace != Namespaces.Message.SecretIncoming {
                                    if let file = media as? TelegramMediaFile, let fileSize = file.size {
                                        let fetchHeadRange: Range<Int> = 0 ..< 2 * 1024 * 1024
                                        let fetchTailRange: Range<Int> = fileSize - 256 * 1024 ..< Int(Int32.max)
                                        
                                        let fetchHeadSignal = fetchedMediaResource(postbox: context.account.postbox, reference: AnyMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), range: (fetchHeadRange, .default), statsCategory: statsCategoryForFileWithAttributes(file.attributes))
                                        |> ignoreValues
                                        |> `catch` { _ -> Signal<Never, NoError> in
                                            return .complete()
                                        }
                                        
                                        let fetchTailSignal = fetchedMediaResource(postbox: context.account.postbox, reference: AnyMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), range: (fetchTailRange, .default), statsCategory: statsCategoryForFileWithAttributes(file.attributes))
                                        |> ignoreValues
                                        |> `catch` { _ -> Signal<Never, NoError> in
                                            return .complete()
                                        }
                                        
                                        let visibilityAwareFetchSignal = strongSelf.visibilityPromise.get()
                                        |> mapToSignal { visibility -> Signal<Void, NoError> in
                                            switch visibility {
                                                case .visible:
                                                    return combineLatest(fetchHeadSignal, fetchTailSignal)
                                                    |> mapToSignal { _ -> Signal<Void, NoError> in
                                                        return .complete()
                                                    }
                                                case .none:
                                                    return .complete()
                                            }
                                        }
                                        strongSelf.fetchDisposable.set(visibilityAwareFetchSignal.start())
                                    }
                                }
                            } else if currentAutomaticDownload != automaticDownload, case .full = automaticDownload {
                                strongSelf.fetchControls.with({ $0 })?.fetch(false)
                            }
                            
                            strongSelf.updateFetchStatus()
                        }
                    })
                })
            })
        }
    }
    
    private func ensureHasTimer() {
        if self.updateTimer == nil {
            let timer = SwiftSignalKit.Timer(timeout: 0.5, repeat: true, completion: { [weak self] in
                self?.updateFetchStatus()
                }, queue: Queue.mainQueue())
            self.updateTimer = timer
            timer.start()
        }
    }
    
    private func stopTimer() {
        self.updateTimer?.invalidate()
        self.updateTimer = nil
    }
    
    private func updateFetchStatus() {
        guard let (theme, strings) = self.themeAndStrings, let sizeCalculation = self.sizeCalculation, let message = self.message, var automaticPlayback = self.automaticPlayback, let wideLayout = self.wideLayout else {
            return
        }
        
        var secretBeginTimeAndTimeout: (Double?, Double)?
        let isSecretMedia = message.containsSecretMedia
        if isSecretMedia {
            for attribute in message.attributes {
                if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
                    if let countdownBeginTime = attribute.countdownBeginTime {
                        secretBeginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                    } else {
                        secretBeginTimeAndTimeout = (nil, Double(attribute.timeout))
                    }
                    break
                }
            }
        }
        
        var webpage: TelegramMediaWebpage?
        var invoice: TelegramMediaInvoice?
        for m in message.media {
            if let m = m as? TelegramMediaWebpage {
                webpage = m
            } else if let m = m as? TelegramMediaInvoice {
                invoice = m
            }
        }
        
        var progressRequired = false
        if secretBeginTimeAndTimeout?.0 != nil {
            progressRequired = true
        } else if let fetchStatus = self.fetchStatus {
            switch fetchStatus {
                case .Local:
                    if let file = media as? TelegramMediaFile, file.isVideo {
                        progressRequired = true
                    } else if isSecretMedia {
                        progressRequired = true
                    } else if let webpage = webpage, case let .Loaded(content) = webpage.content {
                        if content.embedUrl != nil {
                            progressRequired = true
                        } else if let file = content.file, file.isVideo, !file.isAnimated {
                            progressRequired = true
                        }
                    }
                case .Remote, .Fetching:
                    if let webpage = webpage, let automaticDownload = self.automaticDownload, case .full = automaticDownload, case let .Loaded(content) = webpage.content {
                        if content.type == "telegram_background" {
                            progressRequired = true
                        } else if content.embedUrl != nil {
                            progressRequired = true
                        } else if let file = content.file, file.isVideo, !file.isAnimated {
                            progressRequired = true
                        }
                    } else {
                        progressRequired = true
                    }
            }
        }
        
        let radialStatusSize: CGFloat = wideLayout ? 50.0 : 32.0
        
        if progressRequired {
            if self.statusNode == nil {
                let statusNode = RadialStatusNode(backgroundNodeColor: theme.chat.bubble.mediaOverlayControlBackgroundColor)
                let imagePosition = self.imageNode.position
                statusNode.frame = CGRect(origin: CGPoint(x: floor(imagePosition.x - radialStatusSize / 2.0), y: floor(imagePosition.y - radialStatusSize / 2.0)), size: CGSize(width: radialStatusSize, height: radialStatusSize))
                self.statusNode = statusNode
                self.addSubnode(statusNode)
            }
        } else {
            if let statusNode = self.statusNode {
                statusNode.transitionToState(.none, completion: { [weak statusNode] in
                    statusNode?.removeFromSupernode()
                })
                self.statusNode = nil
            }
        }
        
        var state: RadialStatusNodeState = .none
        var badgeContent: ChatMessageInteractiveMediaBadgeContent?
        var mediaDownloadState: ChatMessageInteractiveMediaDownloadState?
        let bubbleTheme = theme.chat.bubble
        if let invoice = invoice {
            let string = NSMutableAttributedString()
            if invoice.receiptMessageId != nil {
                var title = strings.Checkout_Receipt_Title.uppercased()
                if invoice.flags.contains(.isTest) {
                    title += " (Test)"
                }
                string.append(NSAttributedString(string: title))
            } else {
                string.append(NSAttributedString(string: "\(formatCurrencyAmount(invoice.totalAmount, currency: invoice.currency)) ", attributes: [ChatTextInputAttributes.bold: true as NSNumber]))
                
                var title = strings.Message_InvoiceLabel
                if invoice.flags.contains(.isTest) {
                    title += " (Test)"
                }
                string.append(NSAttributedString(string: title))
            }
            badgeContent = .text(inset: 0.0, backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, text: string)
        }
        
        var animated = true
        if var fetchStatus = self.fetchStatus {
            var playerPosition: Int32?
            var playerDuration: Int32 = 0
            var active = false
            var muted = automaticPlayback
            if let playerStatus = self.playerStatus {
                if !playerStatus.generationTimestamp.isZero, case .playing = playerStatus.status {
                    playerPosition = Int32(playerStatus.timestamp + (CACurrentMediaTime() - playerStatus.generationTimestamp))
                } else {
                    playerPosition = Int32(playerStatus.timestamp)
                }
                playerDuration = Int32(playerStatus.duration)
                if case .buffering = playerStatus.status {
                    active = true
                }
                if playerStatus.soundEnabled {
                    muted = false
                }
            } else if case .Fetching = fetchStatus, !message.flags.contains(.Unsent) {
                active = true
            }
            
            if message.flags.contains(.Unsent) {
                automaticPlayback = false
            }
            
            if let actualFetchStatus = self.actualFetchStatus, automaticPlayback {
                fetchStatus = actualFetchStatus
            }
            
            switch fetchStatus {
                case let .Fetching(_, progress):
                    let adjustedProgress = max(progress, 0.027)
                    var wasCheck = false
                    if let statusNode = self.statusNode, case .check = statusNode.state {
                        wasCheck = true
                    }
                    if adjustedProgress.isEqual(to: 1.0), case .unconstrained = sizeCalculation, (message.flags.contains(.Unsent) || wasCheck) {
                        state = .check(bubbleTheme.mediaOverlayControlForegroundColor)
                    } else {
                        state = .progress(color: bubbleTheme.mediaOverlayControlForegroundColor, lineWidth: nil, value: CGFloat(adjustedProgress), cancelEnabled: true)
                    }
                    
                    if let file = self.media as? TelegramMediaFile, (!file.isAnimated || message.flags.contains(.Unsent)) {
                        if wideLayout {
                            if let size = file.size {
                                if let duration = file.duration, !message.flags.contains(.Unsent) {
                                    let durationString = stringForDuration(playerDuration > 0 ? playerDuration : duration, position: playerPosition)
                                    let sizeString = "\(dataSizeString(Int(Float(size) * progress), forceDecimal: true)) / \(dataSizeString(size, forceDecimal: true))"
                                    if isMediaStreamable(message: message, media: file) {
                                        badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: active ? sizeString : nil, muted: muted, active: active)
                                        mediaDownloadState = .fetching(progress: automaticPlayback ? nil : adjustedProgress)
                                        if self.playerStatus?.status == .playing {
                                            mediaDownloadState = nil
                                        }
                                        state = automaticPlayback ? .none : .play(bubbleTheme.mediaOverlayControlForegroundColor)
                                    } else {
                                        if automaticPlayback {
                                            mediaDownloadState = .fetching(progress: adjustedProgress)
                                            badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: active ? sizeString : nil, muted: muted, active: active)
                                        } else {
                                            badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: sizeString, size: nil, muted: false, active: false)
                                        }
                                        state = automaticPlayback ? .none : state
                                    }
                                } else {
                                    badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: "\(dataSizeString(Int(Float(size) * progress), forceDecimal: true)) / \(dataSizeString(size, forceDecimal: true))", size: nil, muted: false, active: false)
                                }
                            } else if let _ = file.duration {
                                badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: strings.Conversation_Processing, size: nil, muted: false, active: active)
                            }
                        } else {
                            if isMediaStreamable(message: message, media: file), let size = file.size {
                                let sizeString = "\(dataSizeString(Int(Float(size) * progress), forceDecimal: true)) / \(dataSizeString(size, forceDecimal: true))"
                                
                                if message.flags.contains(.Unsent), let duration = file.duration {
                                    let durationString = stringForDuration(playerDuration > 0 ? playerDuration : duration, position: playerPosition)
                                    badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: nil, muted: false, active: false)
                                }
                                else if automaticPlayback && !message.flags.contains(.Unsent), let duration = file.duration {
                                    let durationString = stringForDuration(playerDuration > 0 ? playerDuration : duration, position: playerPosition)
                                    badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: active ? sizeString : nil, muted: muted, active: active)
                                    
                                    mediaDownloadState = .fetching(progress: automaticPlayback ? nil : adjustedProgress)
                                    if self.playerStatus?.status == .playing {
                                        mediaDownloadState = nil
                                    }
                                } else {
                                    let progressString = String(format: "%d%%", Int(progress * 100.0))
                                    badgeContent = .text(inset: message.flags.contains(.Unsent) ? 0.0 : 12.0, backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, text: NSAttributedString(string: progressString))
                                    mediaDownloadState = automaticPlayback ? .none : .compactFetching(progress: 0.0)
                                }
                                
                                if !message.flags.contains(.Unsent) {
                                    state = automaticPlayback ? .none : .play(bubbleTheme.mediaOverlayControlForegroundColor)
                                }
                            } else {
                                if let duration = file.duration, !file.isAnimated {
                                    let durationString = stringForDuration(playerDuration > 0 ? playerDuration : duration, position: playerPosition)
                                    
                                    if automaticPlayback, let size = file.size {
                                        let sizeString = "\(dataSizeString(Int(Float(size) * progress), forceDecimal: true)) / \(dataSizeString(size, forceDecimal: true))"
                                        mediaDownloadState = .fetching(progress: progress)
                                        badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: active ? sizeString : nil, muted: muted, active: active)
                                    } else {
                                        badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: nil, muted: false, active: false)
                                    }
                                }
                                
                                state = automaticPlayback ? .none : state
                            }
                        }
                    } else if let webpage = webpage, let automaticDownload = self.automaticDownload, case .full = automaticDownload, case let .Loaded(content) = webpage.content, content.type != "telegram_background" {
                        state = .play(bubbleTheme.mediaOverlayControlForegroundColor)
                    }
                case .Local:
                    state = .none
                    let secretProgressIcon: UIImage?
                    if case .constrained = sizeCalculation {
                        secretProgressIcon = PresentationResourcesChat.chatBubbleSecretMediaIcon(theme)
                    } else {
                        secretProgressIcon = PresentationResourcesChat.chatBubbleSecretMediaCompactIcon(theme)
                    }
                    if isSecretMedia, let (maybeBeginTime, timeout) = secretBeginTimeAndTimeout, let beginTime = maybeBeginTime {
                        state = .secretTimeout(color: bubbleTheme.mediaOverlayControlForegroundColor, icon: secretProgressIcon, beginTime: beginTime, timeout: timeout, sparks: true)
                    } else if isSecretMedia, let secretProgressIcon = secretProgressIcon {
                        state = .customIcon(secretProgressIcon)
                    } else if let file = media as? TelegramMediaFile {
                        let isInlinePlayableVideo = file.isVideo && !isSecretMedia && automaticPlayback
                        if !isInlinePlayableVideo && file.isVideo {
                            state = .play(bubbleTheme.mediaOverlayControlForegroundColor)
                        } else {
                            state = .none
                        }
                    } else if let webpage = webpage, case let .Loaded(content) = webpage.content {
                        if content.embedUrl != nil {
                            state = .play(bubbleTheme.mediaOverlayControlForegroundColor)
                        } else if let file = content.file, file.isVideo, !file.isAnimated {
                            state = .play(bubbleTheme.mediaOverlayControlForegroundColor)
                        }
                    }
                    if let file = media as? TelegramMediaFile, let duration = file.duration, !file.isAnimated {
                        let durationString = stringForDuration(playerDuration > 0 ? playerDuration : duration, position: playerPosition)
                        badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: nil, muted: muted, active: false)
                    }
                case .Remote:
                    state = .download(bubbleTheme.mediaOverlayControlForegroundColor)
                    if let file = self.media as? TelegramMediaFile, !file.isAnimated {
                        let durationString = stringForDuration(playerDuration > 0 ? playerDuration : (file.duration ?? 0), position: playerPosition)
                        if wideLayout {
                            if isMediaStreamable(message: message, media: file) {
                                state = automaticPlayback ? .none : .play(bubbleTheme.mediaOverlayControlForegroundColor)
                                badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: dataSizeString(file.size ?? 0), muted: muted, active: true)
                                mediaDownloadState = .remote
                            } else {
                                state = automaticPlayback ? .none : state
                                badgeContent = .mediaDownload(backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, duration: durationString, size: nil, muted: muted, active: false)
                            }
                        } else {
                            if isMediaStreamable(message: message, media: file) {
                                state = automaticPlayback ? .none : .play(bubbleTheme.mediaOverlayControlForegroundColor)
                                badgeContent = .text(inset: 12.0, backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, text: NSAttributedString(string: durationString))
                                mediaDownloadState = .compactRemote
                            } else {
                                state = automaticPlayback ? .none : state
                                badgeContent = .text(inset: 0.0, backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, text: NSAttributedString(string: durationString))
                            }
                        }
                    } else if let webpage = webpage, let automaticDownload = self.automaticDownload, case .full = automaticDownload, case let .Loaded(content) = webpage.content, content.type != "telegram_background" {
                        state = .play(bubbleTheme.mediaOverlayControlForegroundColor)
                    }
            }
        }
        
        if isSecretMedia, let (maybeBeginTime, timeout) = secretBeginTimeAndTimeout {
            let remainingTime: Int32
            if let beginTime = maybeBeginTime {
                let elapsedTime = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970 - beginTime
                remainingTime = Int32(max(0.0, timeout - elapsedTime))
            } else {
                remainingTime = Int32(timeout)
            }
                        
            badgeContent = .text(inset: 0.0, backgroundColor: bubbleTheme.mediaDateAndStatusFillColor, foregroundColor: bubbleTheme.mediaDateAndStatusTextColor, text: NSAttributedString(string: strings.MessageTimer_ShortSeconds(Int32(remainingTime))))
        }
        
        if let statusNode = self.statusNode {
            if state == .none {
                self.statusNode = nil
            }
            statusNode.transitionToState(state, completion: { [weak statusNode] in
                if state == .none {
                    statusNode?.removeFromSupernode()
                }
            })
        }
        if let badgeContent = badgeContent {
            if self.badgeNode == nil {
                let badgeNode = ChatMessageInteractiveMediaBadge()
                badgeNode.frame = CGRect(origin: CGPoint(x: 6.0, y: 6.0), size: CGSize(width: radialStatusSize, height: radialStatusSize))
                badgeNode.pressed = { [weak self] in
                    guard let strongSelf = self, let fetchStatus = strongSelf.fetchStatus else {
                        return
                    }
                    switch fetchStatus {
                        case .Remote, .Fetching:
                            strongSelf.progressPressed(canActivate: false)
                        default:
                            break
                    }
                }
                self.badgeNode = badgeNode
                self.addSubnode(badgeNode)
                
                animated = false
            }
            self.badgeNode?.update(theme: theme, content: badgeContent, mediaDownloadState: mediaDownloadState, animated: animated)
        } else if let badgeNode = self.badgeNode {
            self.badgeNode = nil
            badgeNode.removeFromSupernode()
        }
        
        if isSecretMedia, secretBeginTimeAndTimeout?.0 != nil {
            if self.secretTimer == nil {
                self.secretTimer = SwiftSignalKit.Timer(timeout: 0.3, repeat: true, completion: { [weak self] in
                    self?.updateFetchStatus()
                }, queue: Queue.mainQueue())
                self.secretTimer?.start()
            }
        } else {
            if let secretTimer = self.secretTimer {
                self.secretTimer = nil
                secretTimer.invalidate()
            }
        }
    }
    
    static func asyncLayout(_ node: ChatMessageInteractiveMediaNode?) -> (_ context: AccountContext, _ theme: PresentationTheme, _ strings: PresentationStrings, _ message: Message, _ media: Media, _ automaticDownload: InteractiveMediaNodeAutodownloadMode, _ peerType: MediaAutoDownloadPeerType, _ sizeCalculation: InteractiveMediaNodeSizeCalculation, _ layoutConstants: ChatMessageItemLayoutConstants, _ contentMode: InteractiveMediaNodeContentMode) -> (CGSize, CGFloat, (CGSize, Bool, Bool, ImageCorners) -> (CGFloat, (CGFloat) -> (CGSize, (ContainedViewLayoutTransition, Bool) -> ChatMessageInteractiveMediaNode))) {
        let currentAsyncLayout = node?.asyncLayout()
        
        return { context, theme, strings, message, media, automaticDownload, peerType, sizeCalculation, layoutConstants, contentMode in
            var imageNode: ChatMessageInteractiveMediaNode
            var imageLayout: (_ context: AccountContext, _ theme: PresentationTheme, _ strings: PresentationStrings, _ message: Message, _ media: Media, _ automaticDownload: InteractiveMediaNodeAutodownloadMode, _ peerType: MediaAutoDownloadPeerType, _ sizeCalculation: InteractiveMediaNodeSizeCalculation, _ layoutConstants: ChatMessageItemLayoutConstants, _ contentMode: InteractiveMediaNodeContentMode) -> (CGSize, CGFloat, (CGSize, Bool, Bool, ImageCorners) -> (CGFloat, (CGFloat) -> (CGSize, (ContainedViewLayoutTransition, Bool) -> Void)))
            
            if let node = node, let currentAsyncLayout = currentAsyncLayout {
                imageNode = node
                imageLayout = currentAsyncLayout
            } else {
                imageNode = ChatMessageInteractiveMediaNode()
                imageLayout = imageNode.asyncLayout()
            }
            
            let (unboundSize, initialWidth, continueLayout) = imageLayout(context, theme, strings, message, media, automaticDownload, peerType, sizeCalculation, layoutConstants, contentMode)
            
            return (unboundSize, initialWidth, { constrainedSize, automaticPlayback, wideLayout, corners in
                let (finalWidth, finalLayout) = continueLayout(constrainedSize, automaticPlayback, wideLayout, corners)
                
                return (finalWidth, { boundingWidth in
                    let (finalSize, apply) = finalLayout(boundingWidth)
                    
                    return (finalSize, { transition, synchronousLoads in
                        apply(transition, synchronousLoads)
                        return imageNode
                    })
                })
            })
        }
    }
    
    func setOverlayColor(_ color: UIColor?, animated: Bool) {
        self.imageNode.setOverlayColor(color, animated: animated)
    }
    
    func isReadyForInteractivePreview() -> Bool {
        if let fetchStatus = self.fetchStatus, case .Local = fetchStatus {
            return true
        } else {
            return false
        }
    }
    
    func updateIsHidden(_ isHidden: Bool) {
        if let badgeNode = self.badgeNode, badgeNode.isHidden != isHidden {
            if isHidden {
                badgeNode.isHidden = true
            } else {
                badgeNode.isHidden = false
                badgeNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    
        if let statusNode = self.statusNode, statusNode.isHidden != isHidden {
            if isHidden {
                statusNode.isHidden = true
            } else {
                statusNode.isHidden = false
                statusNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }
    
    func transitionNode() -> (ASDisplayNode, () -> (UIView?, UIView?))? {
        return (self, { [weak self] in
            var badgeNodeHidden: Bool?
            if let badgeNode = self?.badgeNode {
                badgeNodeHidden = badgeNode.isHidden
                badgeNode.isHidden = true
            }
            var statusNodeHidden: Bool?
            if let statusNode = self?.statusNode {
                statusNodeHidden = statusNode.isHidden
                statusNode.isHidden = true
            }
            
            let view = self?.view.snapshotContentTree(unhide: true)
            
            if let badgeNode = self?.badgeNode, let badgeNodeHidden = badgeNodeHidden {
                badgeNode.isHidden = badgeNodeHidden
            }
            if let statusNode = self?.statusNode, let statusNodeHidden = statusNodeHidden {
                statusNode.isHidden = statusNodeHidden
            }
            return (view, nil)
        })
    }
    
    func playMediaWithSound() -> (() -> Void)? {
        var isAnimated = false
        if let file = self.media as? TelegramMediaFile, file.isAnimated {
            isAnimated = true
        }
        if let videoNode = self.videoNode, let context = self.context, (self.automaticPlayback ?? false) && !isAnimated {
            return {
                let _ = (context.sharedContext.mediaManager.globalMediaPlayerState
                |> take(1)
                |> deliverOnMainQueue).start(next: { playlistStateAndType in
                    var canPlay = true
                    if let (_, state, _) = playlistStateAndType {
                        switch state {
                            case let .state(state):
                                if case .playing = state.status.status {
                                    canPlay = false
                                }
                            case .loading:
                                break
                        }
                    }
                    if canPlay {
                        videoNode.playOnceWithSound(playAndRecord: false, seekToStart: .none)
                    }
                })
            }
        } else {
            return nil
        }
    }
}
