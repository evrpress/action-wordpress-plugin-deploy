#!/bin/bash

# Note that this does not use pipefail
# because if the grep later doesn't match any deleted files,
# which is likely the majority case,
# it does not exit with a 0, and I only care about the final exit.
set -eo

echo "Hello my Friend!"
# Ensure SVN username and password are set
# IMPORTANT: while secrets are encrypted and not viewable in the GitHub UI,
# they are by necessity provided as plaintext in the context of the Action,
# so do not echo or use debug mode unless you want your secrets exposed!
if [[ -z "$SVN_USERNAME" ]]; then
	echo "Set the SVN_USERNAME secret"
	SVN_USERNAME=`grep  "^Contributors:[^\s]*" readme.txt | awk '$1=="Contributors:"{print $2}' | tr -d ','`
fi

if [[ -z "$SVN_USERNAME" ]]; then
	echo "Set the SVN_USERNAME secret"
	exit 1
fi

if [[ -z "$SVN_PASSWORD" ]]; then
	echo "Set the SVN_PASSWORD secret"
	exit 1
fi

# Allow some ENV variables to be customized
if [[ -z "$SLUG" ]]; then
	SLUG=${GITHUB_REPOSITORY#*/}
fi
echo "ℹ︎ SLUG is $SLUG"


MAINFILE="$SLUG.php"

# Check version in readme.txt is the same as plugin file
NEWVERSION1=`grep "^Stable tag" readme.txt | awk -F' ' '{print $3}' | tr -d '\r'`
echo "ℹ︎ Readme version: $NEWVERSION1"
NEWVERSION2=`grep "Version" $MAINFILE | awk -F' ' '{print $2}' | tr -d '\r\n('`
if [ -z "$NEWVERSION2" ]; then
	NEWVERSION2=`grep "Version" $MAINFILE | awk -F' ' '{print $3}' | tr -d '\r'`
fi
echo "ℹ︎ New Version: $NEWVERSION1"
if [ "$NEWVERSION1" != "$NEWVERSION2" ]; then echo "Versions don't match $NEWVERSION1 != $NEWVERSION2. Exiting...."; sleep 5; exit 1; fi

if [[ -z "$VERSION" ]]; then
	VERSION=$NEWVERSION1
fi

echo "ℹ︎ VERSION is $VERSION"

git config user.name "${GITHUB_ACTOR}"
git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

# Check if current version exists as tag
if [[ $(git ls-remote --refs --tags -q | grep "refs/tags/${VERSION}") ]]; then
    echo "Version ${VERSION} exists"
else
    echo "Version ${VERSION} does not exist"
    git tag -fa "${VERSION}" -m "added tag for ${VERSION}"
    git remote set-url origin "https://${GITHUB_ACTOR}:${INPUT_GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
    git push --force origin "${VERSION}"
fi

if [[ -z "$ASSETS_DIR" ]]; then
	ASSETS_DIR=".wordpress-org"
fi
echo "ℹ︎ ASSETS_DIR is $ASSETS_DIR"

SVN_URL="https://plugins.svn.wordpress.org/${SLUG}/"
SVN_DIR="${HOME}/svn-${SLUG}"

# Checkout just trunk and assets for efficiency
# Tagging will be handled on the SVN level
echo "➤ Checking out .org repository..."
svn checkout --depth immediates "$SVN_URL" "$SVN_DIR"
cd "$SVN_DIR"
svn update --set-depth infinity assets
svn update --set-depth infinity trunk

echo "➤ Copying files..."
if [[ -e "$GITHUB_WORKSPACE/.distignore" ]]; then
	echo "ℹ︎ Using .distignore"
	# Copy from current branch to /trunk, excluding dotorg assets
	# The --delete flag will delete anything in destination that no longer exists in source
	rsync -rc --exclude-from="$GITHUB_WORKSPACE/.distignore" "$GITHUB_WORKSPACE/" trunk/ --delete --delete-excluded
else
	echo "ℹ︎ Using .gitattributes"

	cd "$GITHUB_WORKSPACE"

	# "Export" a cleaned copy to a temp directory
	TMP_DIR="${HOME}/archivetmp"
	mkdir "$TMP_DIR"

	# If there's no .gitattributes file, write a default one into place
	if [[ ! -e "$GITHUB_WORKSPACE/.gitattributes" ]]; then
		cat > "$GITHUB_WORKSPACE/.gitattributes" <<-EOL
		/$ASSETS_DIR export-ignore
		/.gitattributes export-ignore
		/.gitignore export-ignore
		/.github export-ignore
		EOL

		# Ensure we are in the $GITHUB_WORKSPACE directory, just in case
		# The .gitattributes file has to be committed to be used
		# Just don't push it to the origin repo :)
		git add .gitattributes && git commit -m "Add .gitattributes file"
	fi

	# This will exclude everything in the .gitattributes file with the export-ignore flag
	git archive HEAD | tar x --directory="$TMP_DIR"

	cd "$SVN_DIR"


	# Copy from clean copy to /trunk, excluding dotorg assets
	# The --delete flag will delete anything in destination that no longer exists in source
	rsync -rc "$TMP_DIR/" trunk/ --delete --delete-excluded
fi

# Copy dotorg assets to /assets
if [[ -d "$GITHUB_WORKSPACE/$ASSETS_DIR/" ]]; then

	echo "➤ Preparing assets..."
	convert -resize 1544x500 $GITHUB_WORKSPACE/$ASSETS_DIR/banner.png $GITHUB_WORKSPACE/$ASSETS_DIR/banner-1544x500.png
	convert -resize 772x250 $GITHUB_WORKSPACE/$ASSETS_DIR/banner.png $GITHUB_WORKSPACE/$ASSETS_DIR/banner-772x250.png
	convert -resize 256x256 $GITHUB_WORKSPACE/$ASSETS_DIR/icon.png $GITHUB_WORKSPACE/$ASSETS_DIR/icon-256x256.png
	convert -resize 128x128 $GITHUB_WORKSPACE/$ASSETS_DIR/icon.png $GITHUB_WORKSPACE/$ASSETS_DIR/icon-128x128.png

	rsync -rc "$GITHUB_WORKSPACE/$ASSETS_DIR/" assets/ --delete
else
	echo "ℹ︎ No assets directory found; skipping asset copy"
fi

# Add everything and commit to SVN
# The force flag ensures we recurse into subdirectories even if they are already added
# Suppress stdout in favor of svn status later for readability
echo "➤ Preparing files..."
svn add . --force > /dev/null

# SVN delete all deleted files
# Also suppress stdout here
svn status | grep '^\!' | sed 's/! *//' | xargs -I% svn rm %@ > /dev/null

# Copy tag locally to make this a single commit

exit;

echo "➤ Copying tag..."
svn cp "trunk" "tags/$VERSION"

# Fix screenshots getting force downloaded when clicking them
# https://developer.wordpress.org/plugins/wordpress-org/plugin-assets/
if test -d "$SVN_DIR/assets" && test -n "$(find "$SVN_DIR/assets" -maxdepth 1 -name "*.png" -print -quit)"; then
    svn propset svn:mime-type "image/png" "$SVN_DIR/assets/*.png" || true
fi
if test -d "$SVN_DIR/assets" && test -n "$(find "$SVN_DIR/assets" -maxdepth 1 -name "*.jpg" -print -quit)"; then
    svn propset svn:mime-type "image/jpeg" "$SVN_DIR/assets/*.jpg" || true
fi
if test -d "$SVN_DIR/assets" && test -n "$(find "$SVN_DIR/assets" -maxdepth 1 -name "*.gif" -print -quit)"; then
    svn propset svn:mime-type "image/gif" "$SVN_DIR/assets/*.gif" || true
fi
if test -d "$SVN_DIR/assets" && test -n "$(find "$SVN_DIR/assets" -maxdepth 1 -name "*.svg" -print -quit)"; then
    svn propset svn:mime-type "image/svg+xml" "$SVN_DIR/assets/*.svg" || true
fi

svn status

ls -a /home/runner/svn-mailster-repermission



echo "➤ Committing files..."
svn commit -m "Update to version $VERSION from GitHub" --no-auth-cache --non-interactive  --username "$SVN_USERNAME" --password "$SVN_PASSWORD"

echo "DONE!"

if $INPUT_GENERATE_ZIP; then
  echo "Generating zip file..."
  cd "$SVN_DIR/trunk" || exit
  zip -r "${GITHUB_WORKSPACE}/${SLUG}.zip" .
  echo "::set-output name=zip-path::${GITHUB_WORKSPACE}/${SLUG}.zip"
  echo "✓ Zip file generated!"
fi

echo "✓ Plugin deployed!"
