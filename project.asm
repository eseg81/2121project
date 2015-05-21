.include "m2560def.inc"
.def col = r16 ; stores the current column being scanned
.def row = r17 ; stores the current row
.def cmask = r18 ; column mask used to determine which column to give low signal
.def rmask = r19 ; row mask used to find out if any row has low signal
.def temp = r20
.def temp2 = r22
.def pattern = r21 ; stores the key pressed 
.def status = r23 ; bit 0 set when in entry mode, bit 1 set when in running mode
				  ; bit 2 set when in paused mode, bit 3 set when in finished mode
				  ; bit 4 set when door open (0 when closed), bit 5 set when power level
				  ; is 100%, bit 6 set when power is 50% and bit 7 is set when power is 25%

.macro is_digit ; checks if the value in pattern is a digit between 0-9
	push temp
	ldi temp, 9
	cpi @0, 0
	brlo not_digit
	cpi temp, @0
	brlo not_digit
	sbr temp, 0 
	bst temp, 0 ; sets the T bit in the SREG if it is a digit
	rjmp end
not_digit:
	cbr temp, 0 ; clears the T bit in the SREG if it is a digit
	bst temp, 0
end:
	pop temp
.endmacro


RESET:
	ldi temp,high(RAMEND) ; sets up the stack pointer
	out SPH,temp
	ldi temp,low(RAMEND)
	out SPL,temp
	ldi temp,0xF0 ; set the columns up for output, rows for input
	sts DDRL,temp
	clr status
	sbr status, 0 ; start off in entry mode with door closed
	

main:
	clr col
	ldi cmask,0xEF ; start off with column 0 having low signal

colloop:
	cpi col,4 ; if got to col 4, start scanning again from col 0
	breq main
	sts PORTL,cmask ; give the current column low signal 
	
	
	;ldi temp,0xFF //debouncing to be added

;delay:                     
	;dec temp
	;cpi temp,0
	;brne delay

	lds temp,PINL ; reads in the signals from PORT L
	andi temp,0x0F ; isolate the input from the rows
	cpi temp,0xF ; if all rows are low, proceed to next col
	breq nextcol
	clr row ; some row is low, need to determine which
	ldi rmask,1 ; starting from row 0

rowloop:
	cpi row,4
	breq nextcol
	mov temp2,temp
	and temp2,rmask ; if the and results in 0 then the current row is low
	breq convert
	lsl rmask ; otherwise check the next row
	inc row
	rjmp rowloop

nextcol:
	inc col ; move on to next col
	lsl cmask
	rjmp colloop

convert: ; arrives here when a low signal has been found 
	cpi col, 3 ; if its in col 3 then a letter is pressed
	breq letters

	cpi row, 3 ; if its in row 3 then a symbol
	breq symbols_or_0 ; or 0 is pressed
	
	ldi temp, 3 ; else a number was pressed
	mul row, temp ; this does 3 * row + col + 1
	mov temp, R0 ; which finds out which number
	inc temp ; is pressed
	add temp,col
	rjmp continue

letters: ; find which letter pressed
	ldi temp, 'A'
	add temp, row
	rjmp continue

symbols_or_0: ; find which symbol pressed, or if 0
	cpi col, 0 ; col 0 is a star
	breq star
	cpi col, 1 ; col 1 is 0
	breq zero
	ldi temp, '#' ; otherwise it is #
	rjmp continue
	
star:
	ldi temp, '*'
	rjmp continue
	
zero:
	ldi temp, 0		 

continue:
	mov pattern,temp
	rjmp act_on_input

act_on_input: ; deals with the key entered on the keypad
	sbrc status, 0 ; deal differently with input depending what mode the microwave is in
	rjmp in_entry_mode
	sbrc status, 1
	rjmp in_running_mode
	sbrc status, 2
	rjmp in_paused_mode
	rjmp in_finished_mode

in_entry_mode:
	cpi pattern, '*'
	breq start_running
	cpi pattern, '#'
	breq clear_entered
	cpi pattern, 'A'
	breq select_power_level
	is_digit pattern
	brts entering_time ; the T bit is set if pattern holds a digit
	jmp main ; if it is none of the above then no operation needs to be done

in_running_mode:
	cpi pattern, '*'
	breq add_one_minute
	cpi pattern, '#'
	breq pause
	cpi pattern, 'C'
	breq add_thirty_seconds
	cpi pattern, 'D'
	breq subtract_thirty_seconds
	jmp main ; if it is none of the above then no operation needs to be done

in_paused_mode:
	cpi pattern, '*'
	breq resume_cooking
	cpi pattern, '#'
	breq cancel_operation
	jmp main ; if it is none of the above then no operation needs to be done

in_finished_mode:
	cpi pattern, '#'
	breq return_to_entry_mode
	jmp main ; if it is none of the above then no operation needs to be done


