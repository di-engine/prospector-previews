#!/usr/bin/env bash
set -uo pipefail

SLUG="${1:?prospect slug required}"
META="prospects/$SLUG/prospect.json"
INDEX="prospects/$SLUG/index.html"
STATUS="deploy-status/$SLUG.json"
test -f "$INDEX" || { echo "Missing $INDEX"; exit 2; }

if [ -f "$META" ]; then
  DISPLAY_NAME=$(jq -r '.display_name // empty' "$META")
  REQUESTED=$(jq -r '.site_name // empty' "$META")
  EXPECTED=$(jq -r '.expected_text // empty' "$META")
else
  DISPLAY_NAME=$(sed -n 's:.*<h1[^>]*>\(.*\)</h1>.*:\1:p' "$INDEX" | head -1 | sed 's/<[^>]*>//g')
  REQUESTED="$SLUG"
  EXPECTED="$DISPLAY_NAME"
fi
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$SLUG"
[ -n "$REQUESTED" ] || REQUESTED="$SLUG"
[ -n "$EXPECTED" ] || EXPECTED="$DISPLAY_NAME"

mkdir -p deploy-status /tmp/prospect-site
rm -rf /tmp/prospect-site/*
cp "$INDEX" /tmp/prospect-site/index.html
cat > /tmp/prospect-site/_headers <<'EOF'
/
  Content-Type: text/html; charset=UTF-8
/index.html
  Content-Type: text/html; charset=UTF-8
EOF
(cd /tmp/prospect-site && zip -q /tmp/prospect-site.zip index.html _headers)

PROVIDER=""
FINAL_URL=""
CONTENT_TYPE=""
NETLIFY_ERROR=""
VERCEL_ERROR=""
NETLIFY_SITE_ID=""
NETLIFY_DEPLOY_ID=""
VERCEL_PROJECT_ID=""
VERCEL_DEPLOY_ID=""

verify_url() {
  local url="$1" expected="$2" result code type
  result=$(curl -L -sS -o /tmp/public.html -w "%{http_code}\n%{content_type}" --max-time 30 "$url" 2>/tmp/verify.err || true)
  code=$(printf '%s\n' "$result" | sed -n '1p')
  type=$(printf '%s\n' "$result" | sed -n '2p')
  CONTENT_TYPE="$type"
  [ "$code" = "200" ] && [[ "$type" == text/html* ]] && grep -Fqi "$expected" /tmp/public.html
}

if [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then
  NETLIFY_SITE_NAME=""
  for CANDIDATE in "$REQUESTED" "${REQUESTED}-24" "${REQUESTED}-dordogne" "${REQUESTED}-$(date +%y%m%d%H%M)"; do
    CODE=$(curl -sS -o /tmp/netlify-site.json -w "%{http_code}" -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" "https://api.netlify.com/api/v1/sites/${CANDIDATE}.netlify.app" || true)
    if [ "$CODE" = "200" ]; then
      NETLIFY_SITE_ID=$(jq -r '.id // empty' /tmp/netlify-site.json)
      NETLIFY_SITE_NAME=$(jq -r '.name // empty' /tmp/netlify-site.json)
      break
    fi
    BODY=$(jq -nc --arg name "$CANDIDATE" '{name:$name}')
    CODE=$(curl -sS -o /tmp/netlify-site.json -w "%{http_code}" -X POST -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" -H "Content-Type: application/json" -d "$BODY" https://api.netlify.com/api/v1/sites || true)
    if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
      NETLIFY_SITE_ID=$(jq -r '.id // empty' /tmp/netlify-site.json)
      NETLIFY_SITE_NAME=$(jq -r '.name // empty' /tmp/netlify-site.json)
      break
    fi
  done

  if [ -n "$NETLIFY_SITE_ID" ]; then
    NETLIFY_URL="https://${NETLIFY_SITE_NAME}.netlify.app"
    CODE=$(curl -sS -o /tmp/netlify-deploy.json -w "%{http_code}" -X PUT -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" -H "Content-Type: application/zip" --data-binary @/tmp/prospect-site.zip "https://api.netlify.com/api/v1/sites/$NETLIFY_SITE_ID" || true)
    if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
      NETLIFY_DEPLOY_ID=$(jq -r '.deploy_id // empty' /tmp/netlify-deploy.json)
      READY=false
      for i in {1..24}; do
        curl -sS -o /tmp/netlify-state.json -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" "https://api.netlify.com/api/v1/deploys/$NETLIFY_DEPLOY_ID" || true
        STATE=$(jq -r '.state // "unknown"' /tmp/netlify-state.json 2>/dev/null || echo unknown)
        [ "$STATE" = "ready" ] && { READY=true; break; }
        [ "$STATE" = "error" ] && break
        sleep 5
      done
      if [ "$READY" = "true" ] && verify_url "$NETLIFY_URL" "$EXPECTED"; then
        PROVIDER="Netlify"
        FINAL_URL="$NETLIFY_URL"
      else
        NETLIFY_ERROR="Netlify deployment or rendering verification failed"
      fi
    else
      NETLIFY_ERROR="Netlify deploy rejected with HTTP $CODE"
    fi
  else
    NETLIFY_ERROR="Netlify project unavailable or creation rejected"
  fi
else
  NETLIFY_ERROR="NETLIFY_AUTH_TOKEN unavailable"
fi

if [ -z "$FINAL_URL" ]; then
  if [ -n "${VERCEL_TOKEN:-}" ]; then
    VERCEL_PROJECT_NAME=""
    for CANDIDATE in "$REQUESTED" "${REQUESTED}-24" "${REQUESTED}-dordogne" "${REQUESTED}-$(date +%y%m%d%H%M)"; do
      CODE=$(curl -sS -o /tmp/vercel-project.json -w "%{http_code}" -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com/v9/projects/$CANDIDATE" || true)
      if [ "$CODE" = "200" ]; then
        VERCEL_PROJECT_ID=$(jq -r '.id // empty' /tmp/vercel-project.json)
        VERCEL_PROJECT_NAME=$(jq -r '.name // empty' /tmp/vercel-project.json)
        break
      fi
      BODY=$(jq -nc --arg name "$CANDIDATE" '{name:$name,framework:null}')
      CODE=$(curl -sS -o /tmp/vercel-project.json -w "%{http_code}" -X POST -H "Authorization: Bearer $VERCEL_TOKEN" -H "Content-Type: application/json" -d "$BODY" https://api.vercel.com/v11/projects || true)
      if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
        VERCEL_PROJECT_ID=$(jq -r '.id // empty' /tmp/vercel-project.json)
        VERCEL_PROJECT_NAME=$(jq -r '.name // empty' /tmp/vercel-project.json)
        break
      fi
    done

    if [ -n "$VERCEL_PROJECT_ID" ]; then
      SHA=$(sha1sum /tmp/prospect-site/index.html | awk '{print $1}')
      SIZE=$(wc -c < /tmp/prospect-site/index.html | tr -d ' ')
      UPLOAD_CODE=$(curl -sS -o /tmp/vercel-upload.json -w "%{http_code}" -X POST -H "Authorization: Bearer $VERCEL_TOKEN" -H "x-vercel-digest: $SHA" -H "Content-Type: application/octet-stream" --data-binary @/tmp/prospect-site/index.html https://api.vercel.com/v2/files || true)
      if [ "$UPLOAD_CODE" = "200" ] || [ "$UPLOAD_CODE" = "201" ]; then
        BODY=$(jq -nc --arg name "$VERCEL_PROJECT_NAME" --arg project "$VERCEL_PROJECT_ID" --arg sha "$SHA" --argjson size "$SIZE" '{name:$name,project:$project,files:[{file:"index.html",sha:$sha,size:$size}],target:"production",projectSettings:{framework:null}}')
        DEPLOY_CODE=$(curl -sS -o /tmp/vercel-deploy.json -w "%{http_code}" -X POST -H "Authorization: Bearer $VERCEL_TOKEN" -H "Content-Type: application/json" -d "$BODY" https://api.vercel.com/v13/deployments || true)
        if [ "$DEPLOY_CODE" = "200" ] || [ "$DEPLOY_CODE" = "201" ]; then
          VERCEL_DEPLOY_ID=$(jq -r '.id // empty' /tmp/vercel-deploy.json)
          UNIQUE_HOST=$(jq -r '.url // empty' /tmp/vercel-deploy.json)
          READY=false
          for i in {1..36}; do
            curl -sS -o /tmp/vercel-state.json -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com/v13/deployments/$VERCEL_DEPLOY_ID" || true
            STATE=$(jq -r '.readyState // .status // "unknown"' /tmp/vercel-state.json 2>/dev/null || echo unknown)
            [ "$STATE" = "READY" ] && { READY=true; break; }
            [ "$STATE" = "ERROR" ] || [ "$STATE" = "CANCELED" ] && break
            sleep 5
          done

          if [ "$READY" = "true" ]; then
            curl -sS -o /tmp/vercel-aliases.json -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com/v2/deployments/$VERCEL_DEPLOY_ID/aliases" || true
            curl -sS -o /tmp/vercel-domains.json -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_NAME/domains" || true
            {
              jq -r '.aliases[]? | if type=="string" then . else (.alias // .domain // .name // empty) end' /tmp/vercel-aliases.json 2>/dev/null || true
              jq -r '.domains[]?.name // empty' /tmp/vercel-domains.json 2>/dev/null || true
              [ -n "$UNIQUE_HOST" ] && echo "$UNIQUE_HOST"
            } | sed '/^$/d' | awk '!seen[$0]++' > /tmp/vercel-candidates.txt

            while IFS= read -r candidate; do
              [ -z "$candidate" ] && continue
              [[ "$candidate" == http* ]] || candidate="https://$candidate"
              if verify_url "$candidate" "$EXPECTED"; then
                PROVIDER="Vercel"
                FINAL_URL="$candidate"
                break
              fi
            done < /tmp/vercel-candidates.txt
          fi
          [ -n "$FINAL_URL" ] || VERCEL_ERROR="Vercel deployment ready but no public alias passed rendering verification"
        else
          VERCEL_ERROR="Vercel deployment creation rejected with HTTP $DEPLOY_CODE"
        fi
      else
        VERCEL_ERROR="Vercel file upload rejected with HTTP $UPLOAD_CODE"
      fi
    else
      VERCEL_ERROR="Vercel project unavailable or creation rejected"
    fi
  else
    VERCEL_ERROR="VERCEL_AUTH_TOKEN unavailable"
  fi
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -n "$FINAL_URL" ]; then
  jq -n --arg prospect "$DISPLAY_NAME" --arg slug "$SLUG" --arg provider "$PROVIDER" --arg url "$FINAL_URL" --arg content_type "$CONTENT_TYPE" --arg netlify_site_id "$NETLIFY_SITE_ID" --arg netlify_deploy_id "$NETLIFY_DEPLOY_ID" --arg vercel_project_id "$VERCEL_PROJECT_ID" --arg vercel_deploy_id "$VERCEL_DEPLOY_ID" --arg verified_at "$NOW" '{prospect:$prospect,slug:$slug,provider:$provider,url:$url,http_status:200,content_type:$content_type,content_verified:true,rendering_verified:true,netlify_site_id:$netlify_site_id,netlify_deploy_id:$netlify_deploy_id,vercel_project_id:$vercel_project_id,vercel_deploy_id:$vercel_deploy_id,verified_at:$verified_at}' > "$STATUS"
  cat "$STATUS"
  exit 0
fi

jq -n --arg prospect "$DISPLAY_NAME" --arg slug "$SLUG" --arg netlify_error "$NETLIFY_ERROR" --arg vercel_error "$VERCEL_ERROR" --arg checked_at "$NOW" '{prospect:$prospect,slug:$slug,provider:null,url:null,content_verified:false,rendering_verified:false,netlify_error:$netlify_error,vercel_error:$vercel_error,checked_at:$checked_at}' > "$STATUS"
cat "$STATUS"
exit 2
