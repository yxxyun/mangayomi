/// Longest Common Substring utilities for subtitle matching.
class LcsUtils {
  /// Compute the longest common substring between [str1] and [str2].
  ///
  /// Returns `{length, sequence, offset}` where [length] is the match length,
  /// [sequence] is the matched text, and [offset] is the start position in [str1].
  static Map<String, dynamic> lcs(String str1, String str2) {
    if (str1.isEmpty || str2.isEmpty) {
      return {'length': 0, 'sequence': '', 'offset': 0};
    }
    var sequence = '';
    var str1Length = str1.length;
    var str2Length = str2.length;
    var num = List.generate(str1Length, (_) => List<int>.filled(str2Length, 0));
    var maxlen = 0;
    var lastSubsBegin = 0;
    var thisSubsBegin = 0;
    for (var i = 0; i < str1Length; i++) {
      for (var j = 0; j < str2Length; j++) {
        if (str1[i] != str2[j]) {
          num[i][j] = 0;
        } else {
          if (i == 0 || j == 0) {
            num[i][j] = 1;
          } else {
            num[i][j] = 1 + num[i - 1][j - 1];
          }
          if (num[i][j] > maxlen) {
            maxlen = num[i][j];
            thisSubsBegin = i - num[i][j] + 1;
            if (lastSubsBegin == thisSubsBegin) {
              sequence += str1[i];
            } else {
              lastSubsBegin = thisSubsBegin;
              sequence = str1.substring(lastSubsBegin, i + 1);
            }
          }
        }
      }
    }
    return {'length': maxlen, 'sequence': sequence, 'offset': thisSubsBegin};
  }

  /// Find the best LCS match for [mainItem] among [targetItems].
  static Map<String, dynamic> findBestLCS(
    String mainName,
    List<String> targetNames,
  ) {
    if (targetNames.isEmpty) {
      return {
        'allLCS': <Map<String, dynamic>>[],
        'bestMatch': null,
        'bestMatchIndex': -1,
      };
    }
    final results = <Map<String, dynamic>>[];
    var bestMatchIndex = 0;
    for (var i = 0; i < targetNames.length; i++) {
      final currentLCS = lcs(mainName, targetNames[i]);
      results.add({'target': targetNames[i], 'lcs': currentLCS});
      if (currentLCS['length'] > results[bestMatchIndex]['lcs']['length']) {
        bestMatchIndex = i;
      }
    }
    return {
      'allLCS': results,
      'bestMatch': results[bestMatchIndex],
      'bestMatchIndex': bestMatchIndex,
    };
  }
}
