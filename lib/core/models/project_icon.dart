/// Curated project identities and searchable activity terms. No UI or I/O.
class ProjectIconChoice {
  const ProjectIconChoice({
    required this.name,
    required this.label,
    required this.searchText,
  });
  final String name;
  final String label;
  final String searchText;
}

class ProjectIconCategory {
  const ProjectIconCategory({
    required this.name,
    required this.label,
    required this.tabIcon,
    required this.icons,
  });
  final String name;
  final String label;
  final String tabIcon;
  final List<String> icons;
}

const projectIconChoices = <String, ProjectIconChoice>{
  "folder-library": ProjectIconChoice(
    name: "folder-library",
    label: "Library folder",
    searchText:
        "folder-library library folder library folder folder-library collection books archive storage group hermes",
  ),
  "repo": ProjectIconChoice(
    name: "repo",
    label: "Repository",
    searchText:
        "repo repository repository repo repo-delete repository git source project hermes",
  ),
  "rocket": ProjectIconChoice(
    name: "rocket",
    label: "Rocket",
    searchText:
        "rocket rocket launch or deploy rocket launch deploy fast start hermes",
  ),
  "beaker": ProjectIconChoice(
    name: "beaker",
    label: "Science",
    searchText:
        "beaker science testing or experimental feature beaker microscope test lab tube science experiment flask hermes",
  ),
  "flame": ProjectIconChoice(
    name: "flame",
    label: "Fire",
    searchText:
        "flame fire flame or fire flame fire hot burn danger popular hermes",
  ),
  "star-full": ProjectIconChoice(
    name: "star-full",
    label: "Star",
    searchText:
        "star-full star full star star-full favorite solid rate best bookmark wish wishlist hermes",
  ),
  "heart": ProjectIconChoice(
    name: "heart",
    label: "Heart",
    searchText:
        "heart heart like or favorite heart like favorite love bookmark wish wishlist hermes",
  ),
  "zap": ProjectIconChoice(
    name: "zap",
    label: "Energy",
    searchText:
        "zap energy zap or flash zap symbol-event flash electric power energy fast hermes",
  ),
  "target": ProjectIconChoice(
    name: "target",
    label: "Goal",
    searchText:
        "target goal target target aim goal bullseye focus point goals preparation training practice hermes",
  ),
  "lightbulb": ProjectIconChoice(
    name: "lightbulb",
    label: "Idea",
    searchText:
        "lightbulb idea idea or suggestion lightbulb light-bulb idea suggestion tip hint smart hermes",
  ),
  "tools": ProjectIconChoice(
    name: "tools",
    label: "Tools",
    searchText:
        "tools tools tools tools settings config repair fix utils hermes",
  ),
  "device-desktop": ProjectIconChoice(
    name: "device-desktop",
    label: "Computer",
    searchText:
        "device-desktop computer virtual machine vm device-desktop computer server remote machine box hermes",
  ),
  "device-mobile": ProjectIconChoice(
    name: "device-mobile",
    label: "Phone",
    searchText:
        "device-mobile phone mobile device device-mobile phone handheld smartphone mobile responsive hermes",
  ),
  "terminal": ProjectIconChoice(
    name: "terminal",
    label: "Terminal",
    searchText:
        "terminal terminal terminal or console terminal console repl console command shell cli hermes",
  ),
  "dashboard": ProjectIconChoice(
    name: "dashboard",
    label: "Dashboard",
    searchText:
        "dashboard dashboard dashboard or overview dashboard panel stats dial overview metrics hermes",
  ),
  "globe": ProjectIconChoice(
    name: "globe",
    label: "World",
    searchText:
        "globe world globe or web globe world internet web international network travel trip international world hermes",
  ),
  "broadcast": ProjectIconChoice(
    name: "broadcast",
    label: "Broadcast",
    searchText:
        "broadcast broadcast broadcast or transmit signal broadcast tower signal connect connection transmit wireless hermes",
  ),
  "cloud": ProjectIconChoice(
    name: "cloud",
    label: "Cloud",
    searchText:
        "cloud cloud cloud service or storage cloud online service storage sync remote hermes",
  ),
  "database": ProjectIconChoice(
    name: "database",
    label: "Database",
    searchText:
        "database database database or data storage database sql storage data server table hermes",
  ),
  "package": ProjectIconChoice(
    name: "package",
    label: "Package",
    searchText:
        "package package package or module package box module library dependency shopping order delivery shipping moving hermes",
  ),
  "book": ProjectIconChoice(
    name: "book",
    label: "Book",
    searchText:
        "book book documentation or reading material book library text read documentation manual guide reading study learning book club hermes",
  ),
  "organization": ProjectIconChoice(
    name: "organization",
    label: "Groups & teams",
    searchText:
        "organization groups & teams organization or company organization organization-filled organization-outline company business group team conference meetup group community networking team family club hermes",
  ),
  "bug": ProjectIconChoice(
    name: "bug",
    label: "Bug",
    searchText:
        "bug bug bug or error bug error issue insect problem defect hermes",
  ),
  "shield": ProjectIconChoice(
    name: "shield",
    label: "Protection",
    searchText:
        "shield protection security or protection shield security protect safety guard hermes",
  ),
  "key": ProjectIconChoice(
    name: "key",
    label: "Key",
    searchText:
        "key key key or password key password secret access security authentication hermes",
  ),
  "gift": ProjectIconChoice(
    name: "gift",
    label: "Gift",
    searchText:
        "gift gift gift box gift present box reward package surprise birthday celebration party presents shopping wish wishlist hermes",
  ),
  "telescope": ProjectIconChoice(
    name: "telescope",
    label: "Telescope",
    searchText:
        "telescope telescope telescope telescope search find explore look space hermes",
  ),
  "home": ProjectIconChoice(
    name: "home",
    label: "Home",
    searchText:
        "home home home page home house main start dashboard house home renovation moving accommodation hermes",
  ),
  "coffee": ProjectIconChoice(
    name: "coffee",
    label: "Coffee",
    searchText:
        "coffee coffee coffee or break time coffee break drink beverage java pause cafe coffee break meetup life & hobbies",
  ),
  "game": ProjectIconChoice(
    name: "game",
    label: "Gaming",
    searchText:
        "game gaming game controller game play controller joystick fun entertainment life & hobbies",
  ),
  "jersey": ProjectIconChoice(
    name: "jersey",
    label: "Sport & clothing",
    searchText:
        "jersey sport & clothing jersey or shirt jersey shirt clothing team sport uniform shopping clothing sport team competition life & hobbies",
  ),
  "music": ProjectIconChoice(
    name: "music",
    label: "Music",
    searchText:
        "music music music note music note sound audio song melody concert festival practice performance life & hobbies",
  ),
  "piano": ProjectIconChoice(
    name: "piano",
    label: "Piano",
    searchText:
        "piano piano piano keys piano music keys instrument sound play lessons practice performance life & hobbies",
  ),
  "device-camera": ProjectIconChoice(
    name: "device-camera",
    label: "Photography",
    searchText:
        "device-camera photography camera device device-camera capture picture image photo screenshot travel photography photos holiday life & hobbies",
  ),
  "device-camera-video": ProjectIconChoice(
    name: "device-camera-video",
    label: "Film & video",
    searchText:
        "device-camera-video film & video video camera device-camera-video movie record capture video film life & hobbies",
  ),
  "mic": ProjectIconChoice(
    name: "mic",
    label: "Voice & podcasting",
    searchText:
        "mic voice & podcasting microphone or audio mic microphone audio voice record sound life & hobbies",
  ),
  "symbol-color": ProjectIconChoice(
    name: "symbol-color",
    label: "Art & colour",
    searchText:
        "symbol-color art & colour color symbol symbol-color code paint palette type style art painting creative design life & hobbies",
  ),
  "wand": ProjectIconChoice(
    name: "wand",
    label: "Magic",
    searchText:
        "wand magic magic wand wand magic fix auto spell wizard life & hobbies",
  ),
  "map": ProjectIconChoice(
    name: "map",
    label: "Map",
    searchText:
        "map map map map map-horizontal fold-horizontal location guide plan chart area travel trip holiday itinerary tour road trip life & hobbies",
  ),
  "location": ProjectIconChoice(
    name: "location",
    label: "Place",
    searchText:
        "location place location or place location map place pin marker gps travel trip destination venue conference life & hobbies",
  ),
  "compass": ProjectIconChoice(
    name: "compass",
    label: "Exploration",
    searchText:
        "compass exploration compass for navigation compass navigate direction orient guide map travel trip exploration hiking adventure life & hobbies",
  ),
  "snake": ProjectIconChoice(
    name: "snake",
    label: "Snake",
    searchText:
        "snake snake snake snake python reptile game animal curve life & hobbies",
  ),
  "squirrel": ProjectIconChoice(
    name: "squirrel",
    label: "Wildlife",
    searchText:
        "squirrel wildlife squirrel squirrel animal ship release deploy mascot life & hobbies",
  ),
  "ruby": ProjectIconChoice(
    name: "ruby",
    label: "Gem",
    searchText:
        "ruby gem ruby language ruby language code gem jewel red life & hobbies",
  ),
  "pulse": ProjectIconChoice(
    name: "pulse",
    label: "Health & fitness",
    searchText:
        "pulse health & fitness pulse or activity pulse heartbeat activity monitor line health health fitness training exercise life & hobbies",
  ),
  "magnet": ProjectIconChoice(
    name: "magnet",
    label: "Magnetism",
    searchText:
        "magnet magnetism magnet magnet stick snap attract pull hold life & hobbies",
  ),
  "eye": ProjectIconChoice(
    name: "eye",
    label: "Vision",
    searchText:
        "eye vision view or watch eye eye-unwatch eye-watch view watch see visibility preview life & hobbies",
  ),
  "briefcase": ProjectIconChoice(
    name: "briefcase",
    label: "Business",
    searchText:
        "briefcase business work or business related briefcase work workplace business professional job business conference business trip career life & hobbies work & study",
  ),
  "calendar": ProjectIconChoice(
    name: "calendar",
    label: "Planning",
    searchText:
        "calendar planning calendar or schedule calendar day time week month date schedule event planner conference event appointment trip holiday preparation schedule work & study",
  ),
  "clockface": ProjectIconChoice(
    name: "clockface",
    label: "Time",
    searchText:
        "clockface time clock face showing time clockface time watch schedule history wait hour minute time preparation deadline work & study",
  ),
  "checklist": ProjectIconChoice(
    name: "checklist",
    label: "Tasks",
    searchText:
        "checklist tasks checklist or task list checklist checkmark select checked mark complete finish done todo task list checklist goals packing packing list planning preparation shopping tasks work & study",
  ),
  "mortar-board": ProjectIconChoice(
    name: "mortar-board",
    label: "Learning",
    searchText:
        "mortar-board learning mortar board or graduation mortar-board education learn school degree hat study exam learning course preparation work & study",
  ),
  "law": ProjectIconChoice(
    name: "law",
    label: "Law",
    searchText:
        "law law legal or license law legal license terms compliance legal policy contracts work & study",
  ),
  "credit-card": ProjectIconChoice(
    name: "credit-card",
    label: "Money",
    searchText:
        "credit-card money payment or credit card credit-card payment merchant money billing purchase shopping purchases budget payments expenses life & hobbies",
  ),
  "edit": ProjectIconChoice(
    name: "edit",
    label: "Writing",
    searchText:
        "edit writing edit or modify edit pencil pencil modify write change update writing drafting preparation work & study",
  ),
  "note": ProjectIconChoice(
    name: "note",
    label: "Notes",
    searchText:
        "note notes note or memo note document memo text write conference study meeting journal preparation work & study",
  ),
  "table": ProjectIconChoice(
    name: "table",
    label: "Spreadsheet",
    searchText:
        "table spreadsheet table table grid data rows columns sheet work & study",
  ),
  "graph": ProjectIconChoice(
    name: "graph",
    label: "Analytics",
    searchText:
        "graph analytics graph or chart graph chart visualization data analytics statistics work & study",
  ),
  "project": ProjectIconChoice(
    name: "project",
    label: "Project board",
    searchText:
        "project project board project or workspace project workspace folder solution repository planning preparation projects work & study",
  ),
  "archive": ProjectIconChoice(
    name: "archive",
    label: "Archive",
    searchText:
        "archive archive archive or package items archive save box delivery package store compress work & study",
  ),
  "tag": ProjectIconChoice(
    name: "tag",
    label: "Label",
    searchText:
        "tag label tag or label tag git-pull-request-label tag-add tag-remove label mark version release shopping sale prices purchases life & hobbies",
  ),
  "symbol-ruler": ProjectIconChoice(
    name: "symbol-ruler",
    label: "Measuring",
    searchText:
        "symbol-ruler measuring ruler symbol symbol-ruler symbol-unit code measure size scale unit renovation building making measuring work & study",
  ),
  "symbol-operator": ProjectIconChoice(
    name: "symbol-operator",
    label: "Mathematics",
    searchText:
        "symbol-operator mathematics operator symbol symbol-operator code math logic calc function work & study",
  ),
  "layers": ProjectIconChoice(
    name: "layers",
    label: "Layers",
    searchText:
        "layers layers layers layers stack sheets levels overlay group work & study",
  ),
  "search": ProjectIconChoice(
    name: "search",
    label: "Research",
    searchText:
        "search research search or find search search-save find query look magnify locate work & study",
  ),
  "person": ProjectIconChoice(
    name: "person",
    label: "Person",
    searchText:
        "person person person or user person person-follow person-outline person-filled user account profile human contact personal individual speaker guest people & events",
  ),
  "comment-discussion": ProjectIconChoice(
    name: "comment-discussion",
    label: "Conversation",
    searchText:
        "comment-discussion conversation discussion or conversation comment-discussion dialog message bubble chat conversation feedback conference meeting discussion networking conversation people & events",
  ),
  "mail": ProjectIconChoice(
    name: "mail",
    label: "Email",
    searchText:
        "mail email email or mail mail email message envelope communication people & events",
  ),
  "megaphone": ProjectIconChoice(
    name: "megaphone",
    label: "Announcements",
    searchText:
        "megaphone announcements megaphone megaphone shout announce broadcast loud speaker notification conference talk public speaking announcement campaign people & events",
  ),
  "mention": ProjectIconChoice(
    name: "mention",
    label: "Social media",
    searchText:
        "mention social media mention or @ symbol mention at tag user notify address collaborate communication people & events",
  ),
  "send": ProjectIconChoice(
    name: "send",
    label: "Correspondence",
    searchText:
        "send correspondence send message send mail message submit paper plane go people & events",
  ),
  "rss": ProjectIconChoice(
    name: "rss",
    label: "News & feeds",
    searchText:
        "rss news & feeds rss feed rss feed news subscribe broadcast wifi people & events",
  ),
  "smiley": ProjectIconChoice(
    name: "smiley",
    label: "Mood",
    searchText:
        "smiley mood smiley face smiley face happy emotion good smile people & events",
  ),
  "link": ProjectIconChoice(
    name: "link",
    label: "Connections",
    searchText:
        "link connections link or reference link url hyperlink connection chain reference people & events",
  ),
  "code": ProjectIconChoice(
    name: "code",
    label: "Coding",
    searchText:
        "code coding code or programming code embed script programming development source tech & tools",
  ),
  "json": ProjectIconChoice(
    name: "json",
    label: "Structured data",
    searchText:
        "json structured data json format json bracket bracket data format code structure tech & tools",
  ),
  "markdown": ProjectIconChoice(
    name: "markdown",
    label: "Markdown",
    searchText:
        "markdown markdown markdown format markdown text format document md writing tech & tools",
  ),
  "browser": ProjectIconChoice(
    name: "browser",
    label: "Website",
    searchText:
        "browser website web browser or webpage browser web internet page window site tech & tools",
  ),
  "chip": ProjectIconChoice(
    name: "chip",
    label: "Processor",
    searchText:
        "chip processor computer chip or processor chip hardware processor cpu gpu silicon integrated tech & tools",
  ),
  "circuit-board": ProjectIconChoice(
    name: "circuit-board",
    label: "Electronics",
    searchText:
        "circuit-board electronics circuit board or iot device circuit-board iot device process hardware technology tech & tools",
  ),
  "server": ProjectIconChoice(
    name: "server",
    label: "Server",
    searchText:
        "server server server or host server host backend database remote tech & tools",
  ),
  "plug": ProjectIconChoice(
    name: "plug",
    label: "Power & connections",
    searchText:
        "plug power & connections plugin or extension plug extension connect addon power tech & tools",
  ),
  "robot": ProjectIconChoice(
    name: "robot",
    label: "Robotics",
    searchText:
        "robot robotics robot robot ai bot automation machine android tech & tools",
  ),
  "vr": ProjectIconChoice(
    name: "vr",
    label: "Virtual reality",
    searchText:
        "vr virtual reality vr headset vr virtual reality glasses headset 3d tech & tools",
  ),
  "record-keys": ProjectIconChoice(
    name: "record-keys",
    label: "Keyboard",
    searchText:
        "record-keys keyboard record keystrokes record-keys keyboard macro type input save keyboard tech & tools",
  ),
  "extensions": ProjectIconChoice(
    name: "extensions",
    label: "Plugins",
    searchText:
        "extensions plugins extensions or plugins extensions plugin addon package module marketplace tech & tools",
  ),
  "gear": ProjectIconChoice(
    name: "gear",
    label: "Mechanics",
    searchText:
        "gear mechanics settings or configuration gear settings configuration preferences options setup tech & tools",
  ),
  "git-branch": ProjectIconChoice(
    name: "git-branch",
    label: "Version control",
    searchText:
        "git-branch version control git branch git-branch git-branch-create git-branch-delete source control version tree fork tech & tools",
  ),
  "notebook": ProjectIconChoice(
    name: "notebook",
    label: "Computational notebook",
    searchText:
        "notebook computational notebook notebook or interactive document notebook jupyter code document interactive tech & tools",
  ),
  "folder": ProjectIconChoice(
    name: "folder",
    label: "Folder",
    searchText:
        "folder folder folder or directory folder file-directory symbol-folder directory container storage organize work & study",
  ),
  "milestone": ProjectIconChoice(
    name: "milestone",
    label: "Signpost",
    searchText:
        "milestone signpost milestone milestone git-pull-request-milestone goal target flag marker progress git project issue pr travel trip wayfinding journey checkpoints preparation goal life & hobbies",
  ),
  "flag": ProjectIconChoice(
    name: "flag",
    label: "Flag",
    searchText:
        "flag flag flag flag mark report notice banner sign event festival competition goal checkpoint preparation work & study",
  ),
};

const projectIconCategories = <ProjectIconCategory>[
  ProjectIconCategory(
    name: "hermes",
    label: "Hermes",
    tabIcon: "folder-library",
    icons: [
      "folder-library",
      "repo",
      "rocket",
      "beaker",
      "flame",
      "star-full",
      "heart",
      "zap",
      "target",
      "lightbulb",
      "tools",
      "device-desktop",
      "device-mobile",
      "terminal",
      "dashboard",
      "globe",
      "broadcast",
      "cloud",
      "database",
      "package",
      "book",
      "organization",
      "bug",
      "shield",
      "key",
      "gift",
      "telescope",
      "home",
    ],
  ),
  ProjectIconCategory(
    name: "life",
    label: "Life & hobbies",
    tabIcon: "music",
    icons: [
      "coffee",
      "game",
      "jersey",
      "music",
      "piano",
      "device-camera",
      "device-camera-video",
      "mic",
      "symbol-color",
      "wand",
      "snake",
      "squirrel",
      "ruby",
      "pulse",
      "magnet",
      "eye",
      "map",
      "location",
      "compass",
      "briefcase",
      "credit-card",
      "tag",
      "milestone",
    ],
  ),
  ProjectIconCategory(
    name: "work",
    label: "Work & study",
    tabIcon: "briefcase",
    icons: [
      "folder",
      "briefcase",
      "calendar",
      "clockface",
      "checklist",
      "mortar-board",
      "law",
      "edit",
      "note",
      "table",
      "graph",
      "project",
      "archive",
      "symbol-ruler",
      "symbol-operator",
      "layers",
      "search",
      "flag",
    ],
  ),
  ProjectIconCategory(
    name: "people",
    label: "People & events",
    tabIcon: "person",
    icons: [
      "person",
      "comment-discussion",
      "mail",
      "megaphone",
      "mention",
      "send",
      "rss",
      "smiley",
      "link",
    ],
  ),
  ProjectIconCategory(
    name: "tech",
    label: "Tech & tools",
    tabIcon: "chip",
    icons: [
      "code",
      "json",
      "markdown",
      "browser",
      "chip",
      "circuit-board",
      "server",
      "plug",
      "robot",
      "vr",
      "record-keys",
      "extensions",
      "gear",
      "git-branch",
      "notebook",
    ],
  ),
];

List<ProjectIconChoice> searchProjectIcons(String query) {
  final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
  return List.unmodifiable(
    projectIconChoices.values.where(
      (icon) => words.every(icon.searchText.contains),
    ),
  );
}

String projectIconLabel(String? name) => name == null || name.isEmpty
    ? 'Default icon'
    : projectIconChoices[name]?.label ?? name;
