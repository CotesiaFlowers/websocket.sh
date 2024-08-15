#!/bin/sh

CRLF="$(printf '\r\n_')"
CRLF="${CRLF%?}"

trim() { awk '{$1=$1};1' ; }
size() { printf '%s' "$1" | wc -c ; }
readBytes() { dd bs="$1" count=1 2>/dev/null ; }
readDecimals() { readBytes "$1" | od -A n -t u1 | trim ; }
randomDecimals() { openssl rand "$1" | readDecimals "$1" ; }

# shellcheck disable=SC2048
promote() {
	i=0; printf '%s' $(("0$(for byte in $*; do printf '%s' "|$byte<<$((i * 8))"; i=$(( i + 1 )); done)"))
}

# shellcheck disable=SC2030
ParseHTTP() {
	while IFS=$CRLF read -r line && [ -n "$line" ]; do
		case "$line" in
			HTTP*) status="${line#*[[:blank:]]}" ;; # HTTP |(200 OK)
				*) export "$(printf '%s' "${line%%:*}" | sed 's/-/_/g')=${line#*:[[:blank:]]}" ;; # (Content-Type)|: application/json = Content-Type: |(application/json)
		esac
	done

	if [ "$Content_Type" = "application/json" ]; then
		if [ "$Transfer_Encoding" = "chunked" ]; then
			read -r length
			while [ "$length" != "0" ]; do
				read -r chunk
				body="$body$chunk"
				read -r _crlf
				read -r length
				length="${length%?}"
			done
		fi
	fi

	echo "${status%%[[:blank:]]*}" "$body"
}

# shellcheck disable=SC2086
WebSocketDecodeLength() {
	if   [ "$1" -eq 126 ]; then
		setList "A B"             "$(readDecimals 2)" && promote                   $B $A
	elif [ "$1" -eq 127 ]; then
		setList "A B C D E F G H" "$(readDecimals 8)" && promote $H $G $F $E $D $C $B $A
	else
		printf '%s' "$1"
	fi
}

WebSocketDecodeTextFrame() {
	length="$(WebSocketDecodeLength "$(readDecimals 1)")"
	payload="$(readBytes "$length")"
	while [ ! "$length" -eq "$(size "$payload")" ]; do
		payload="$payload$(readBytes $(( length - $(size "$payload") )))"
	done
	printf '%s' "$payload"
}

WebSocketDecodeCloseFrame() { setList "A B" "$(readDecimals "$(readDecimals 1)")" && promote $B $A ; }

WebSocketDecode() {
	while true; do
		header="$(readDecimals 1)"

		case "$header" in
			129) echo "$(WebSocketDecodeTextFrame)" ;;
			136) # close
				break
			;;
			*)
				if [ -n "$header" ]; then
					>&2 echo "WebSocketDecode encountered an unhandled header type: ($header)"
					break
				fi
			;;
		esac
	done
}

WebSocketConnect() {
	host="${1##*/}"

	 in=$(mktemp -u -p /tmp/websocket.sh) && mkfifo "$in"  && exec 3<>"$in"
	out=$(mktemp -u -p /tmp/websocket.sh) && mkfifo "$out" && exec 4<>"$out"
	err=$(mktemp -u -p /tmp/websocket.sh) && mkfifo "$err" && exec 5<>"$err"

	openssl s_client -quiet -connect "$host:443" -state -nbio <&3 1>&4 2>&5 &
	OPENSSL_PID="$!"

	read -r line <&5 && [ "${line#*"Connecting"}" = "$line" ] && return 1

	printf '%s\r\n' \
		"GET $3 HTTP/1.1" \
		"Host: $host" \
		"Connection: Upgrade" \
		"Upgrade: websocket" \
		"Sec-WebSocket-Key: $( (openssl rand 16 | base64) )" \
		"Sec-WebSocket-Version: 13" \
		"Origin: $2" \
		"" >&3

	_=$(ParseHTTP <&4)

	cat <&4

	return 0
}

# shellcheck disable=SC2059
WebSocketCreateMessage() {
	header="$(if [ -n "$2" ]; then printf "$2"; else printf '\201'; fi)"
	printf '%s' "$header"

	length="${#1}"
	if [ "$length" -gt 0 ] && [ "$length" -le 125 ]; then
		printf "\\$( printf '%o' "$(( length | 128 ))" )"
	elif [ "$length" -gt 125 ]; then
		printf '%06o' "$length" | {
			codes="$codes\\$(readBytes 3)"
			codes="$codes\\$(readBytes 3)"
			printf "\376$codes"
		}
	fi

	mask=$(randomDecimals 4)

	for byte in $mask; do printf "\\$(printf '%o' $byte)"; done

	i=0
	for byte in $(printf '%s' "$1" | readDecimals "$length")
	do
		byte=$(( byte ^ $( at "$mask" $((i % 4 + 1)) )))
		printf "\\$(printf '%o' $byte)"
		i=$((i + 1))
	done
}

WebSocketSend() { WebSocketCreateMessage "$1" >&3; }
