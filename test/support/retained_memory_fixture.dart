Map<String, dynamic> currentMemoryGraph() => {
  'memory': [
    {
      'source': 'memory',
      'title': 'First memory',
      'body': 'First preview',
      'fingerprint': '111111111111',
    },
    {
      'source': 'profile',
      'title': 'Second memory',
      'body': 'Second preview',
      'fingerprint': '222222222222',
    },
  ],
  'nodes': [
    {
      'id': 'memory:memory:0:111111111111',
      'kind': 'memory',
      'label': 'First memory',
      'memorySource': 'memory',
    },
    {
      'id': 'memory:profile:1:222222222222',
      'kind': 'memory',
      'label': 'Second memory',
      'memorySource': 'profile',
    },
  ],
};

Map<String, dynamic> currentMemoryDetail(String identity) => {
  'ok': true,
  'kind': 'memory',
  'id': identity,
  'label': 'Second memory',
  'content': 'Full second memory',
};
