podman build --no-cache --rm -f Containerfile -t horizon:demo .
podman run --interactive --tty -p 8000:8000 horizon:demo
echo "browse http://localhost:8000/?name=Test"
