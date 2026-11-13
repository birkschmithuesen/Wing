/// Copied disclosure facts; no native path or destination authority.
class SharedDraftFile {
  const SharedDraftFile({
    required this.name,
    required this.byteLength,
    required this.isImage,
  });
  final String name;
  final int byteLength;
  final bool isImage;
}

class SharedDraftProfile {
  const SharedDraftProfile({required this.name, required this.label});
  final String name, label;
}

class SharedDraftDestination {
  const SharedDraftDestination({
    required this.id,
    required this.label,
    required this.presentationId,
    required this.profileSelection,
  });
  final String id, label, presentationId;
  final Object profileSelection;
}

class SharedDraftRecovery {
  const SharedDraftRecovery({
    required this.profileName,
    required this.text,
    required this.attachmentCount,
    required this.queuedCount,
  });
  final String profileName, text;
  final int attachmentCount, queuedCount;
}

class SharedDraftNotice {
  const SharedDraftNotice(this.message, {required this.error});
  final String message;
  final bool error;
}

class SharedDraftState {
  const SharedDraftState({
    required this.hasPending,
    required this.reviewing,
    required this.discarding,
    required this.canReview,
  });
  final bool hasPending, reviewing, discarding, canReview;
}

class SharedDraftReviewState {
  SharedDraftReviewState({
    required this.text,
    required Iterable<SharedDraftFile> files,
    required this.connectionLabel,
    required this.profileName,
    required Iterable<SharedDraftProfile> profiles,
    required this.destination,
    required Iterable<SharedDraftDestination> destinations,
    required this.recovery,
    required this.destinationNotice,
    required this.working,
    required this.canLoadMore,
    required this.loadingMore,
    required this.loadMoreLabel,
    required this.pageError,
    required this.addLabel,
    required this.error,
  }) : files = List.unmodifiable(files),
       profiles = List.unmodifiable(profiles),
       destinations = List.unmodifiable(destinations);
  final String? text;
  final List<SharedDraftFile> files;
  final String connectionLabel, profileName, destination;
  final List<SharedDraftProfile> profiles;
  final List<SharedDraftDestination> destinations;
  final SharedDraftRecovery? recovery;
  final String? destinationNotice, error, pageError;
  final bool working, canLoadMore, loadingMore;
  final String loadMoreLabel, addLabel;
}
