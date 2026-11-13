# 보안 정책 / Security policy

보안 취약점을 발견하셨다면 **공개 이슈 대신** 이 레포의 **Security → Report a vulnerability**(비공개 취약점 신고)로 알려 주세요. 확인 후 답변드리고, 고친 버전을 릴리스하면서 함께 안내합니다.

If you find a security issue, please **do not open a public issue**. Use **Security → Report a vulnerability** in this repository to report it privately. We will reply after checking and announce the fix with a release.

`serve` 는 기본으로 내 컴퓨터(127.0.0.1)에서만 접속되며, 개발용 토큰이나 `app_check.mode: off` 설정으로는 다른 주소에서 대기하지 않습니다. / By default `serve` only listens on your own machine (127.0.0.1), and it refuses to listen on any other address while dev tokens or `app_check.mode: off` are configured.
