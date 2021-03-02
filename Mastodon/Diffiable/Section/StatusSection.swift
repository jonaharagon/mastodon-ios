//
//  TimelineSection.swift
//  Mastodon
//
//  Created by sxiaojian on 2021/1/27.
//

import Combine
import CoreData
import CoreDataStack
import os.log
import UIKit

enum StatusSection: Equatable, Hashable {
    case main
}

extension StatusSection {
    static func tableViewDiffableDataSource(
        for tableView: UITableView,
        dependency: NeedsDependency,
        managedObjectContext: NSManagedObjectContext,
        timestampUpdatePublisher: AnyPublisher<Date, Never>,
        timelinePostTableViewCellDelegate: StatusTableViewCellDelegate,
        timelineMiddleLoaderTableViewCellDelegate: TimelineMiddleLoaderTableViewCellDelegate?
    ) -> UITableViewDiffableDataSource<StatusSection, Item> {
        UITableViewDiffableDataSource(tableView: tableView) { [weak timelinePostTableViewCellDelegate, weak timelineMiddleLoaderTableViewCellDelegate] tableView, indexPath, item -> UITableViewCell? in
            guard let timelinePostTableViewCellDelegate = timelinePostTableViewCellDelegate else { return UITableViewCell() }

            switch item {
            case .homeTimelineIndex(objectID: let objectID, let attribute):
                let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: StatusTableViewCell.self), for: indexPath) as! StatusTableViewCell

                // configure cell
                managedObjectContext.performAndWait {
                    let timelineIndex = managedObjectContext.object(with: objectID) as! HomeTimelineIndex
                    StatusSection.configure(cell: cell, readableLayoutFrame: tableView.readableContentGuide.layoutFrame, timestampUpdatePublisher: timestampUpdatePublisher, toot: timelineIndex.toot, requestUserID: timelineIndex.userID, statusContentWarningAttribute: attribute)
                }
                cell.delegate = timelinePostTableViewCellDelegate
                return cell
            case .toot(let objectID, let attribute):
                let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: StatusTableViewCell.self), for: indexPath) as! StatusTableViewCell
                let activeMastodonAuthenticationBox = dependency.context.authenticationService.activeMastodonAuthenticationBox.value
                let requestUserID = activeMastodonAuthenticationBox?.userID ?? ""
                // configure cell
                managedObjectContext.performAndWait {
                    let toot = managedObjectContext.object(with: objectID) as! Toot
                    StatusSection.configure(cell: cell, readableLayoutFrame: tableView.readableContentGuide.layoutFrame, timestampUpdatePublisher: timestampUpdatePublisher, toot: toot, requestUserID: requestUserID, statusContentWarningAttribute: attribute)
                }
                cell.delegate = timelinePostTableViewCellDelegate
                return cell
            case .publicMiddleLoader(let upperTimelineTootID):
                let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: TimelineMiddleLoaderTableViewCell.self), for: indexPath) as! TimelineMiddleLoaderTableViewCell
                cell.delegate = timelineMiddleLoaderTableViewCellDelegate
                timelineMiddleLoaderTableViewCellDelegate?.configure(cell: cell, upperTimelineTootID: upperTimelineTootID, timelineIndexobjectID: nil)
                return cell
            case .homeMiddleLoader(let upperTimelineIndexObjectID):
                let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: TimelineMiddleLoaderTableViewCell.self), for: indexPath) as! TimelineMiddleLoaderTableViewCell
                cell.delegate = timelineMiddleLoaderTableViewCellDelegate
                timelineMiddleLoaderTableViewCellDelegate?.configure(cell: cell, upperTimelineTootID: nil, timelineIndexobjectID: upperTimelineIndexObjectID)
                return cell
            case .bottomLoader:
                let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: TimelineBottomLoaderTableViewCell.self), for: indexPath) as! TimelineBottomLoaderTableViewCell
                cell.activityIndicatorView.startAnimating()
                return cell
            }
        }
    }

    static func configure(
        cell: StatusTableViewCell,
        readableLayoutFrame: CGRect?,
        timestampUpdatePublisher: AnyPublisher<Date, Never>,
        toot: Toot,
        requestUserID: String,
        statusContentWarningAttribute: StatusContentWarningAttribute?
    ) {
        // set header
        cell.statusView.headerContainerStackView.isHidden = toot.reblog == nil
        cell.statusView.headerInfoLabel.text = {
            let author = toot.author
            let name = author.displayName.isEmpty ? author.username : author.displayName
            return L10n.Common.Controls.Status.userBoosted(name)
        }()
        
        // set name username avatar
        cell.statusView.nameLabel.text = {
            let author = (toot.reblog ?? toot).author
            return author.displayName.isEmpty ? author.username : author.displayName
        }()
        cell.statusView.usernameLabel.text = "@" + (toot.reblog ?? toot).author.acct
        cell.statusView.configure(with: AvatarConfigurableViewConfiguration(avatarImageURL: (toot.reblog ?? toot).author.avatarImageURL()))
        
        // set text
        cell.statusView.activeTextLabel.config(content: (toot.reblog ?? toot).content)
        
        // set status text content warning
        let spoilerText = (toot.reblog ?? toot).spoilerText ?? ""
        let isStatusTextSensitive = statusContentWarningAttribute?.isStatusTextSensitive ?? !spoilerText.isEmpty
        cell.statusView.isStatusTextSensitive = isStatusTextSensitive
        cell.statusView.updateContentWarningDisplay(isHidden: !isStatusTextSensitive)
        cell.statusView.contentWarningTitle.text = {
            if spoilerText.isEmpty {
                return L10n.Common.Controls.Status.statusContentWarning
            } else {
                return L10n.Common.Controls.Status.statusContentWarning + ": \(spoilerText)"
            }
        }()
        
        // prepare media attachments
        let mediaAttachments = Array((toot.reblog ?? toot).mediaAttachments ?? []).sorted { $0.index.compare($1.index) == .orderedAscending }
        
        // set image
        let mosiacImageViewModel = MosaicImageViewModel(mediaAttachments: mediaAttachments)
        let imageViewMaxSize: CGSize = {
            let maxWidth: CGFloat = {
                // use timelinePostView width as container width
                // that width follows readable width and keep constant width after rotate
                let containerFrame = readableLayoutFrame ?? cell.statusView.frame
                var containerWidth = containerFrame.width
                containerWidth -= 10
                containerWidth -= StatusView.avatarImageSize.width
                return containerWidth
            }()
            let scale: CGFloat = {
                switch mosiacImageViewModel.metas.count {
                case 1:     return 1.3
                default:    return 0.7
                }
            }()
            return CGSize(width: maxWidth, height: maxWidth * scale)
        }()
        if mosiacImageViewModel.metas.count == 1 {
            let meta = mosiacImageViewModel.metas[0]
            let imageView = cell.statusView.statusMosaicImageView.setupImageView(aspectRatio: meta.size, maxSize: imageViewMaxSize)
            imageView.af.setImage(
                withURL: meta.url,
                placeholderImage: UIImage.placeholder(color: .systemFill),
                imageTransition: .crossDissolve(0.2)
            )
        } else {
            let imageViews = cell.statusView.statusMosaicImageView.setupImageViews(count: mosiacImageViewModel.metas.count, maxHeight: imageViewMaxSize.height)
            for (i, imageView) in imageViews.enumerated() {
                let meta = mosiacImageViewModel.metas[i]
                imageView.af.setImage(
                    withURL: meta.url,
                    placeholderImage: UIImage.placeholder(color: .systemFill),
                    imageTransition: .crossDissolve(0.2)
                )
            }
        }
        cell.statusView.statusMosaicImageView.isHidden = mosiacImageViewModel.metas.isEmpty
        let isStatusSensitive = statusContentWarningAttribute?.isStatusSensitive ?? (toot.reblog ?? toot).sensitive
        cell.statusView.statusMosaicImageView.blurVisualEffectView.effect = isStatusSensitive ? MosaicImageViewContainer.blurVisualEffect : nil
        cell.statusView.statusMosaicImageView.vibrancyVisualEffectView.alpha = isStatusSensitive ? 1.0 : 0.0
        
        // set poll
        if let poll = (toot.reblog ?? toot).poll {
            cell.statusView.statusPollTableView.isHidden = false
            
            let managedObjectContext = toot.managedObjectContext!
            cell.statusView.statusPollTableViewDataSource = PollSection.tableViewDiffableDataSource(
                for: cell.statusView.statusPollTableView,
                managedObjectContext: managedObjectContext
            )
            
            var snapshot = NSDiffableDataSourceSnapshot<PollSection, PollItem>()
            snapshot.appendSections([.main])
            let pollItems = poll.options
                .sorted(by: { $0.index.intValue < $1.index.intValue })
                .map { option -> PollItem in
                    let isVoted = (option.votedBy ?? Set()).map { $0.id }.contains(requestUserID)
                    let attribute = PollItem.Attribute(voted: isVoted)
                    let option = PollItem.opion(objectID: option.objectID, attribute: attribute)
                    return option
                }
            snapshot.appendItems(pollItems, toSection: .main)
            cell.statusView.statusPollTableViewDataSource?.apply(snapshot, animatingDifferences: false, completion: nil)
            // cell.statusView.statusPollTableView.layoutIfNeeded()
        } else {
            cell.statusView.statusPollTableView.isHidden = true
        }

        // toolbar
        let replyCountTitle: String = {
            let count = (toot.reblog ?? toot).repliesCount?.intValue ?? 0
            return StatusSection.formattedNumberTitleForActionButton(count)
        }()
        cell.statusView.actionToolbarContainer.replyButton.setTitle(replyCountTitle, for: .normal)
        
        let isLike = (toot.reblog ?? toot).favouritedBy.flatMap { $0.contains(where: { $0.id == requestUserID }) } ?? false
        let favoriteCountTitle: String = {
            let count = (toot.reblog ?? toot).favouritesCount.intValue
            return StatusSection.formattedNumberTitleForActionButton(count)
        }()
        cell.statusView.actionToolbarContainer.starButton.setTitle(favoriteCountTitle, for: .normal)
        cell.statusView.actionToolbarContainer.isStarButtonHighlight = isLike
        
        // set date
        let createdAt = (toot.reblog ?? toot).createdAt
        cell.statusView.dateLabel.text = createdAt.shortTimeAgoSinceNow
        timestampUpdatePublisher
            .sink { _ in
                cell.statusView.dateLabel.text = createdAt.shortTimeAgoSinceNow
            }
            .store(in: &cell.disposeBag)

        // observe model change
        ManagedObjectObserver.observe(object: toot.reblog ?? toot)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // do nothing
            } receiveValue: { change in
                guard case .update(let object) = change.changeType,
                      let newToot = object as? Toot else { return }
                let targetToot = newToot.reblog ?? newToot

                let isLike = targetToot.favouritedBy.flatMap { $0.contains(where: { $0.id == requestUserID }) } ?? false
                let favoriteCount = targetToot.favouritesCount.intValue
                let favoriteCountTitle = StatusSection.formattedNumberTitleForActionButton(favoriteCount)
                cell.statusView.actionToolbarContainer.starButton.setTitle(favoriteCountTitle, for: .normal)
                cell.statusView.actionToolbarContainer.isStarButtonHighlight = isLike
                os_log("%{public}s[%{public}ld], %{public}s: like count label for toot %s did update: %ld", (#file as NSString).lastPathComponent, #line, #function, targetToot.id, favoriteCount)
            }
            .store(in: &cell.disposeBag)
    }
}

extension StatusSection {
    private static func formattedNumberTitleForActionButton(_ number: Int?) -> String {
        guard let number = number, number > 0 else { return "" }
        return String(number)
    }
}
