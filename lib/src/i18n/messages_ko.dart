// 한국어 문구. messages_en.dart 와 키 집합이 같아야 한다(test/i18n_test.dart 가 확인).

const Map<String, String> messagesKo = {
  // ---- 도움말 ----
  'help.global':
      '''flutter_llm_proxy {version} - Flutter·웹 앱에 LLM API 키를 넣지 않게 해 주는 프록시.
순수 Dart 서버라 Flutter SDK 가 필요 없습니다.

사용법: flutter_llm_proxy <명령> [옵션]

명령:
  serve          프록시 실행: App Check 검증, 사용량 한도, 버퍼링 없는 스트리밍
  demo           연습용 목(mock)으로 전체 흐름을 오프라인으로 보여 주기(API 키 불필요)
  check-config   설정 파일을 검사하고 무엇을 허용하는지 요약

공통 옵션:
  --lang en|ko   출력 언어(없으면 FLUTTER_LLM_PROXY_LANG, 그다음 LC_ALL / LC_MESSAGES / LANG)
  --version      버전 출력
  -h, --help     이 도움말

명령별 옵션은 "flutter_llm_proxy <명령> --help" 로 보세요.''',
  'help.serve': '''사용법: flutter_llm_proxy serve --config <파일> [옵션]

프록시를 실행합니다. 제공자 키는 서버 환경 변수(설정에 적은 이름, 예: OPENAI_API_KEY)
에서만 읽고 앱에는 절대 전달되지 않습니다.

옵션:
  -c, --config <파일>   YAML 설정(example/proxy.yaml 참고)
  --mock                연습용 목 업스트림: 응답은 녹화 형식 샘플이고 키·네트워크 불필요
  --host <주소>         대기 주소(기본 127.0.0.1, 컨테이너에서는 0.0.0.0)
  --port <번호>         대기 포트(기본: PORT 환경 변수, 없으면 8080)
  --lang en|ko          출력·로그 언어

개발용 토큰이나 "app_check.mode: off" 는 루프백이 아닌 주소에서 거부합니다(종료 코드 2).
Ctrl+C 로 멈춥니다.''',
  'help.demo': '''사용법: flutter_llm_proxy demo [옵션]

진짜 프록시 코드를 이 프로세스 안에서 로컬 JWKS(직접 만든 RSA 키)와 연습용 목 업스트림에
연결해 돌리고, 앱이 보게 될 결과를 보여 줍니다. API 키·Firebase 프로젝트·네트워크가 필요 없습니다.

옵션:
  --only all|security|limits|buffering   한 부분만 실행(기본 all)
  --delay-ms <밀리초>                    목 스트림 이벤트 간격(기본 250)
  --lang en|ko                           출력 언어

모든 결과가 기대와 같으면 종료 코드 0, 아니면 1.''',
  'help.check-config': '''사용법: flutter_llm_proxy check-config <파일> [--strict]

설정을 검사하고 어떤 제공자·경로·모델·한도가 열리는지 출력합니다.
키 환경 변수는 설정됨/설정 안 됨만 보여 주고 값은 절대 출력하지 않습니다.

옵션:
  --strict       경고가 있으면 종료 코드 1
  --lang en|ko   출력 언어

종료 코드: 0 정상, 1 --strict 에서 경고, 2 잘못된 설정(줄 번호·키 경로 표시).''',

  // ---- cli ----
  'cli.usage_error': '사용법 오류: {detail}',
  'cli.see_help': '"flutter_llm_proxy --help" 로 사용법을 보세요.',
  'cli.bad_lang': '알 수 없는 언어 "{value}". en 또는 ko 를 쓰세요.',
  'cli.bad_delay': '--delay-ms 값이 잘못됐습니다: "{value}" (10~5000).',
  'cli.bad_port': '포트 값이 잘못됐습니다: "{value}".',
  'cli.config_error': '설정 오류 {file}, {line}번째 줄, 키 {path}: {message}',
  'cli.check_needs_file':
      'check-config 에는 설정 파일 하나가 필요합니다. 예: flutter_llm_proxy check-config example/proxy.yaml',
  'cli.serve_needs_config':
      'serve 에는 --config <파일> 이 필요합니다. 예: flutter_llm_proxy serve --config example/proxy.yaml --mock',

  // ---- 설정 오류 ----
  'cli.config_not_found':
      '설정 파일이 없습니다: {path} (example/proxy.yaml 을 복사해서 시작하세요)',
  'config.file_not_found': '파일이 없습니다: {path}',
  'config.yaml_syntax': 'YAML 문법 오류: {detail}',
  'config.expected_map': '키: 값 형태의 묶음이어야 합니다',
  'config.unknown_key': '모르는 키 "{key}" (쓸 수 있는 키: {allowed})',
  'config.expected_string': '글자 값이어야 합니다',
  'config.expected_bool': 'true 또는 false 여야 합니다',
  'config.expected_int': '정수여야 합니다',
  'config.negative': '음수일 수 없습니다(값: {value})',
  'config.expected_list': '목록이어야 합니다',
  'config.missing': '필수 설정이 없습니다',
  'config.no_providers': '제공자가 하나 이상 있어야 합니다',
  'config.duplicate_prefix': '접두사 {prefix} 를 두 제공자가 함께 씁니다',
  'config.bad_choice': '"{value}" 는 다음 중 하나여야 합니다: {choices}',
  'config.bad_prefix': '접두사는 "/" 로 시작하고 "/" 로 끝나지 않아야 합니다(값: "{value}")',
  'config.bad_url': 'http(s) 주소가 아닙니다: {value}',
  'config.bad_path': '허용 경로는 "/" 로 시작해야 합니다(값: "{value}")',
  'config.bad_project_number':
      'project_number 는 숫자여야 합니다(Firebase 프로젝트 ID 가 아니라 프로젝트 번호): {value}',
  'config.local_needs_jwks': 'mode local 에는 jwks_file 또는 jwks_url 이 필요합니다',

  // ---- 설정 경고 ----
  'warn.app_check_off':
      'app_check.mode 가 off 입니다: 프록시에 닿는 누구나 내 키를 쓸 수 있습니다. 로컬 개발용으로만 쓰세요.',
  'warn.dev_tokens':
      '개발용 토큰 {count}개가 설정됨: App Check 를 건너뛰는 고정 문자열입니다. 로컬 개발용으로만 쓰세요.',
  'warn.no_allowed_app_ids':
      'allowed_app_ids 가 비어 있어 Firebase 프로젝트의 모든 앱을 받습니다.',
  'warn.any_model':
      '제공자 {provider}: allowed_models 가 비어 있어 클라이언트가 아무(비싼) 모델이나 고를 수 있습니다.',
  'warn.no_request_limit': 'limits.requests_per_minute 가 없어 주체별 요청 한도가 없습니다.',
  'warn.cors_any':
      'cors.allow_origins 에 "*" 가 있어 어떤 웹사이트든 브라우저에서 프록시를 부를 수 있습니다.',
  'warn.trust_forwarded_for':
      'trust_forwarded_for 가 켜져 있습니다: X-Forwarded-For 를 덮어쓰는 리버스 프록시 뒤에서만 안전합니다.',
  'warn.key_not_set':
      '제공자 {provider}: 환경 변수 {env} 가 설정되지 않았습니다(--mock 이 아니면 serve 가 시작을 거부합니다).',

  // ---- check-config ----
  'cc.header': '설정: {file}',
  'cc.app_check':
      'App Check: 모드 {mode}, 프로젝트 번호 {number} (ID {id}), 허용 앱: {apps}',
  'cc.jwks': '  JWKS: {source}',
  'cc.providers': '제공자:',
  'cc.provider':
      '  {id} ({type})  {prefix}/... -> {upstream}  키: {env} ({header} 방식) [{state}]',
  'cc.key_set': '설정됨',
  'cc.key_not_set': '설정 안 됨',
  'cc.paths': '    경로: {paths}',
  'cc.models': '    모델: {models}',
  'cc.include_usage': '    stream_options.include_usage 주입: {value}',
  'cc.limits':
      '한도: 주체 {subject}, 분당 요청 {rpm}, 주체별 하루 토큰 {tpd}, 전체 하루 토큰 {global}',
  'cc.cors': 'CORS 허용 출처: {origins}',
  'cc.misc': '요청 본문 상한: {bytes}바이트, X-Forwarded-For 신뢰: {xff}',
  'cc.any': '모두',
  'cc.none': '없음',
  'cc.on': '켜짐',
  'cc.off': '꺼짐',
  'cc.unlimited': '제한 없음',
  'cc.no_warnings': '경고: 없음',
  'cc.warnings': '경고 {count}개:',
  'cc.strict_fail': '--strict: 경고 {count}개, 종료 코드 1.',
  'cc.ok': '설정이 올바릅니다.',

  // ---- serve ----
  'serve.refuse_public':
      '{host} 에서 대기하지 않습니다: 개발용 토큰이나 app_check.mode off 면 누구나 내 키를 쓸 수 있습니다. 127.0.0.1 을 쓰거나 그 설정을 지우세요.',
  'serve.missing_keys':
      '서버 키 환경 변수가 없습니다: {envs}. 값을 설정하거나 먼저 --mock 으로 해 보세요.',
  'serve.bind_failed': '{host}:{port} 에서 대기할 수 없습니다: {detail}',
  'serve.mock_banner':
      '목 모드(연습용): 업스트림 응답은 녹화 형식 샘플이며 실제 모델이 아닙니다. 키가 이 컴퓨터 밖으로 나가지 않습니다.',
  'serve.warning': '경고: {text}',
  'serve.listening': 'flutter_llm_proxy {version} 대기 중: {url} (Ctrl+C 로 멈춤)',
  'serve.route': '  {prefix}/... -> {upstream}',
  'serve.stopping': '멈추는 중.',

  // ---- 요청 로그 ----
  'log.request':
      '{time} {method} {path} {status} 주체={subject} 토큰={tokens} {ms}ms{notes}',
  'log.usage_missing': '(usage 없음)',
  'log.client_disconnected': '(클라이언트 연결 끊김)',

  // ---- 데모 ----
  'demo.banner':
      'flutter_llm_proxy 데모 - 연습용 목(mock) 모드: 업스트림은 녹화 형식 샘플을 재생하는 로컬 목이며 실제 모델이 아닙니다.\nAPI 키·Firebase 프로젝트·네트워크가 필요 없습니다. 프록시 코드 자체는 진짜입니다.',
  'demo.setup': '준비: 로컬 JWKS {jwks} (직접 만든 RSA-2048 키 "{kid}"), 목 업스트림 {mock}',
  'demo.section_security': '[1/3] App Check - 내 앱만 프록시를 쓸 수 있게',
  'demo.section_limits': '[2/3] 한도 - 앱+IP 마다 분당 3회',
  'demo.section_buffering':
      '[3/3] 스트리밍 - shelf 버퍼링 끔 vs 켬 (목 이벤트 간격 {delay}ms)',
  'demo.row': '  {mark}  {scenario}  기대 {expected}, 결과 {got}',
  'demo.mark_ok': '통과',
  'demo.mark_fail': '실패',
  'demo.s_valid': '정상 토큰(aud 는 2개짜리 목록), 스트림',
  'demo.got_stream': '{status} 스트림 (이벤트 {events}개)',
  'demo.s_missing': '토큰 없음',
  'demo.s_bad_aud': '이 프로젝트 번호가 없는 aud',
  'demo.s_hs256': '공개키로 위조한 HS256',
  'demo.s_expired': '만료된 토큰',
  'demo.s_tampered': '내용 바꿔치기(서명 불일치)',
  'demo.lib_accepted': '통과',
  'demo.lib_rejected': '거부',
  'demo.aud_note':
      '  참고: 같은 정상 토큰을 라이브러리의 "aud 완전 일치" 검사에 넣으면 {result}. App Check 의 aud 는 목록이라 프록시는 "포함" 여부를 봅니다.',
  'demo.upstream_key': '  업스트림이 서버 키를 받음: {value}',
  'demo.upstream_appcheck': '  업스트림이 App Check 토큰을 받음: {value}',
  'demo.client_key': '앱(클라이언트)이 키를 봄: {value}',
  'demo.s_request': '{n}번째 요청',
  'demo.limits_note': '  한도는 서버 인스턴스마다 메모리에서 셉니다. 검증에 실패한 토큰은 이 단계에 오지 않습니다.',
  'demo.s_buffer_off': 'buffer_output=false (이 프록시)',
  'demo.s_buffer_on': 'shelf 기본값 (buffer_output=true)',
  'demo.expect_early': '첫 청크가 전체의 50% 전',
  'demo.expect_late': '첫 청크가 전체의 50% 이후',
  'demo.got_timing': '첫 청크 {first}ms / 전체 {total}ms',
  'demo.buffer_note': '  기본값이면 앱은 답이 다 끝날 때까지 아무것도 못 받습니다 - 스트리밍이 조용히 사라집니다.',
  'demo.yes': '예',
  'demo.no': '아니오',
  'demo.log_header': '프록시 로그(요청마다 한 줄, 키·토큰 원문은 출력하지 않음):',
  'demo.summary_ok': '검사 {n}개 모두 기대와 같습니다(연습용 목). 종료 코드 0.',
  'demo.summary_fail': '검사 {total}개 중 {n}개가 기대와 다릅니다. 종료 코드 1.',
};
