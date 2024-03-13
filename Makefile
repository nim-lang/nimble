publish-guide:
	# CURRENT_BRANCH="$$(git rev-parse --abbrev-ref HEAD)"; \
	# 	if [[ "$${CURRENT_BRANCH}" != "master" ]]; then \
	# 		echo -e "\nWarning: you're publishing the books from the 'master' branch!\n"; \
	# 	fi
	cd nimble-guide && \
	mkdocs build && \
	cd .. && \
	git worktree add tmp-book gh-pages && \
	cp -a nimble-guide/site/* tmp-book/ && \
	cd tmp-book && \
	git add . && { \
		git commit -m "make publish-guide $$(git rev-parse --short HEAD)" && \
		git push origin gh-pages || true; } && \
	cd .. && \
	git worktree remove -f tmp-book && \
	rm -rf tmp-book
