.include "m2560def.inc"
.def col = r16 ; stores the current column being scanned
.def row = r17 ; stores the current row
.def cmask = r18 ; column mask used to determine which column to give low signal
.def rmask = r19 ; row mask used to find out if any row has low signal
.def temp = r20
.def temp2 = r22
.def pattern = r21 ; stores the key pressed 
.def status = r23 ; this keeps track of current mode, door 
				  ; open or closed and power level

RESET:
	ldi temp,high(RAMEND) ; sets up the stack pointer
	out SPH,temp
	ldi temp,low(RAMEND)
	out SPL,temp
	ldi temp,0xF0 ; set the columns up for output, rows for input
	sts DDRL,temp

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
	rjmp main
