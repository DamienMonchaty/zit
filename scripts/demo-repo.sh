#!/bin/bash
# A small made-up repository for screenshots: four authors, branches merged
# and not, tags, a stash, and changes both staged and not. Its path is the
# first argument, .zig-cache/demo/acme-web by default; it is made afresh.
set -e
D="${1:-/tmp/acme-web}"
rm -rf "$D"; mkdir -p "$D"; cd "$D"
git init -q -b main
git config commit.gpgsign false
git config user.name "Alice Martin"; git config user.email alice@acme.dev
T=1761300000
c() { # author email msg file
  T=$((T+5400))
  echo "$3" >> "$4"
  git add -A
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" \
  GIT_AUTHOR_DATE="@$T +0100" GIT_COMMITTER_DATE="@$T +0100" git commit -q -m "$3"
}
w() { # author email msg — what is already written
  T=$((T+5400))
  git add -A
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" \
  GIT_AUTHOR_DATE="@$T +0100" GIT_COMMITTER_DATE="@$T +0100" git commit -q -m "$3"
}
m() { # branch msg author email
  T=$((T+5400))
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
  GIT_AUTHOR_DATE="@$T +0100" GIT_COMMITTER_DATE="@$T +0100" git merge -q --no-ff "$1" -m "$2"
}
A="Alice Martin"; a=alice@acme.dev
B="Bob Chen"; b=bob@acme.dev
C="Chloé Dubois"; cc=chloe@acme.dev
E="Diego Ramos"; e=diego@acme.dev
mkdir -p src/components src/api docs
c "$A" $a "chore: scaffold the project" README.md
c "$A" $a "feat: app shell and router" src/app.ts
c "$B" $b "feat(api): HTTP client with retries" src/api/client.ts
git tag v0.1.0
git checkout -q -b develop
c "$C" $cc "feat(ui): button and input components" src/components/Button.tsx
c "$B" $b "feat(api): typed endpoints" src/api/endpoints.ts
git checkout -q -b feature/WEB-12-login
# A real file, so a commit of it reads as a diff.
cat > src/components/Login.tsx <<'TSX'
import { useState } from "react";
import { signIn } from "../api/session";

export function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    await signIn(email, password);
  }

  return (
    <form onSubmit={submit}>
      <input value={email} onChange={(e) => setEmail(e.target.value)} />
      <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button type="submit">Sign in</button>
    </form>
  );
}
TSX
w "$C" $cc "WEB-12: login form"
cat > src/components/Login.tsx <<'TSX'
import { useState } from "react";
import { signIn } from "../api/session";

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!EMAIL.test(email)) return setError("That email does not look right.");
    setError(null);
    await signIn(email, password);
  }

  return (
    <form onSubmit={submit}>
      <input value={email} onChange={(e) => setEmail(e.target.value)} aria-invalid={error !== null} />
      {error && <p role="alert">{error}</p>}
      <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button type="submit">Sign in</button>
    </form>
  );
}
TSX
w "$C" $cc "WEB-12: validate the email field"
c "$B" $b "WEB-12: session token refresh" src/api/session.ts
git checkout -q develop
git checkout -q -b feature/WEB-18-search
c "$E" $e "WEB-18: search box with debounce" src/components/Search.tsx
c "$E" $e "WEB-18: highlight the matches" src/components/Search.tsx
git checkout -q develop
m feature/WEB-12-login "Merge branch 'feature/WEB-12-login' into develop" "$A" $a
c "$A" $a "docs: how to run the app locally" docs/setup.md
git checkout -q main
m develop "Release 1.0" "$A" $a
git tag v1.0.0
git checkout -q -b fix/WEB-21-header
c "$B" $b "fix: header overlaps the menu on small screens" src/components/Header.tsx
git checkout -q develop
c "$C" $cc "feat(ui): dark theme" src/theme.css
c "$E" $e "perf: lazy-load the dashboard" src/app.ts
m feature/WEB-18-search "Merge branch 'feature/WEB-18-search' into develop" "$A" $a
c "$C" $cc "feat(ui): empty states" src/components/Empty.tsx
c "$B" $b "test(api): endpoints against a mock server" src/api/endpoints.test.ts
git checkout -q -b feature/WEB-24-notifications
c "$E" $e "WEB-24: notification bell" src/components/Bell.tsx
c "$E" $e "WEB-24: mark all as read" src/components/Bell.tsx
git checkout -q develop
# a stash and work in progress
echo "export const RETRIES = 3;" >> src/api/client.ts
git stash -q -m "try fewer retries"
printf 'export function Search() {\n  // TODO: keyboard navigation\n}\n' >> src/components/Search.tsx
echo "Use \`npm run dev\` and open http://localhost:5173." >> docs/setup.md
echo "export const PAGE_SIZE = 50;" > src/api/paging.ts
git add docs/setup.md
echo "$D"
