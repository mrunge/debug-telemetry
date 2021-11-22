README.html: README.md
	pandoc -o $@ $<
